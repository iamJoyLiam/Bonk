//
//  HostKeyProbe.swift
//  Bonk
//
//  A credential-free probe: obtains a server's host key and verifies it against
//  a trust file without ever sending a credential.
//
//  ## Why this exists
//
//  The canonical store needs the public-key material for a host, but a bare
//  SHA-256 pin cannot be inverted into one. So for a host we have pinned but not
//  stored key material for, and for a host we have never contacted, one
//  handshake is required to learn the key. That handshake must never carry
//  credentials — otherwise a password or private key would be sent to a host
//  whose identity is not yet established, which is exactly the violation AGENTS.md
//  forbids.
//
//  ## The guarantee
//
//  `PreferredAuthentications=none` is the load-bearing flag: it disables the
//  *methods*, whereas `BatchMode=yes` alone only suppresses prompting, so a
//  stale agent or key could still be offered. `IdentityFile=none` stops default
//  identity files loading at all; `IdentityAgent=none` closes the agent path.
//  All three are needed, and `LC_ALL=C` keeps the diagnostics the classifier
//  keys on stable across locales.
//
//  ## Ordering
//
//  The probe runs *before* any credential-bearing connection. Discovering an
//  unknown host during the real connect would mean credentials are already in
//  flight when the answer arrives, and by then the damage is done.
//

import Foundation

/// Performs a credential-free host-key probe.
public struct HostKeyProbe: Sendable {
    /// Bounded so a wedged host cannot hang a connection indefinitely.
    ///
    /// The deadline is enforced by the caller as a hard stop, not by ssh's own
    /// `ConnectTimeout`: that option only bounds the TCP connect, and a server
    /// that accepts and then goes silent never trips it. Observed during
    /// development — a stalled KEX ran for the full outer deadline.
    public static let defaultTimeout: Duration = .seconds(30)

    // `nonisolated(unsafe)` because `FileManager` is not `Sendable`. It is used
    // only for path-level operations, which FileManager documents as
    // thread-safe, and is never re-pointed after construction.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The credential-free flag set.
    ///
    /// Kept as a constant so every probe uses the same isolation and a future
    /// edit cannot silently loosen one path. `LC_ALL=C` is applied to the
    /// environment, not assumed.
    private static let isolationOptions: [String] = [
        "StrictHostKeyChecking=yes",
        "GlobalKnownHostsFile=/dev/null",
        "PreferredAuthentications=none",
        "PubkeyAuthentication=no",
        "PasswordAuthentication=no",
        "KbdInteractiveAuthentication=no",
        "NumberOfPasswordPrompts=0",
        "BatchMode=yes",
        "IdentitiesOnly=yes",
        "IdentityFile=none",
        "IdentityAgent=none",
    ]

    /// Probe a host against a trust file containing exactly `record`.
    ///
    /// The caller supplies the candidate record and the probe writes it to an
    /// isolated temporary `known_hosts`, so the key under test is always the one
    /// the caller identified and never a key ssh happens to remember.
    ///
    /// - Returns: the classified outcome. Never throws for a failed probe; a
    ///   failure *is* the result, and throwing would force every caller to
    ///   distinguish transport errors from trust outcomes.
    public func probe(
        host: String,
        port: UInt16,
        candidate: HostKeyRecord,
        timeout: Duration = HostKeyProbe.defaultTimeout
    ) async -> ProbeOutcome {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("hostkey-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .inconclusive
        }
        defer { try? fileManager.removeItem(at: directory) }

        let trustFile = directory.appendingPathComponent("known_hosts")
        do {
            try Data(
                HostKeyKnownHostsRenderer.render(host: host, port: port, records: [candidate]).utf8
            ).write(to: trustFile)
            _ = chmod(trustFile.path, mode_t(0o600))
        } catch {
            // A trust file that cannot be written proves nothing. This is not a
            // server-side rejection.
            return .inconclusive
        }

        let algorithms = HostKeyBlob.signatureAlgorithms(forKeyType: candidate.keyType)
            .joined(separator: ",")

        return await withTaskGroup(of: (Int32, String, Bool).self) { group in
            group.addTask {
                await Self.spawn(
                    host: host, port: port, trustFile: trustFile.path,
                    algorithms: algorithms, directory: directory
                )
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return (0, "", true)
            }

            var result = (Int32(0), "", false)
            if let first = await group.next() {
                result = first
            }
            group.cancelAll()
            return ProbeOutcomeClassifier.classify(
                status: result.0, timedOut: result.2, stderr: result.1
            )
        }
    }

    /// Run `/usr/bin/ssh` with every credential path disabled.
    ///
    /// Isolated so the probe inherits nothing from the developer or user
    /// environment that could change what ssh does: `BONK_TEST_*` markers, an
    /// inherited `DISPLAY`, a user `ssh_config`.
    private static func spawn(
        host: String,
        port: UInt16,
        trustFile: String,
        algorithms: String,
        directory: URL
    ) async -> (Int32, String, Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-v",
            "-F", "/dev/null",
            "-o", "UserKnownHostsFile=\(trustFile)",
            "-o", "HostKeyAlgorithms=\(algorithms)",
            "-o", "ConnectTimeout=10",
        ] + isolationOptions.map { ["-o", $0] }.flatMap { $0 }
            + ["-p", String(port), "probe@\(host)", "true"]

        var environment = ProcessInfo.processInfo.environment
        // Only what ssh needs; `LC_ALL=C` makes the diagnostics the classifier
        // parses stable across machine locales.
        environment = [
            "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C",
        ]
        process.environment = environment
        process.currentDirectoryURL = directory

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return (-1, "probe launch failed: \(error)", false)
        }

        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text, false)
    }
}