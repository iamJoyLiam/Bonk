//
//  OpenSSHKnownHostsResolver.swift
//  Bonk
//
//  The single entry point that turns a host into the `known_hosts` file ssh must
//  use. Every OpenSSH argv path goes through here, so there is one trust policy
//  rather than one per call site.
//
//  ## The priority chain, and why it ends in a throw
//
//      explicit override (test/debug)
//        → canonical record exists  → render
//        → no record                → probe → CAS → render
//        → probe fails              → throw
//
//  There is deliberately no fourth branch. Falling back to `~/.ssh/known_hosts`
//  or to `accept-new` would make the canonical store advisory rather than
//  authoritative: ssh would keep its own trust file, keep accepting unseen keys,
//  and AUDIT-FIND-001 would still be live with a green test standing behind it.
//  A host we cannot vouch for must fail closed.
//
//  ## Why the caller sees only a URL
//
//  The caller should not know whether a record was found, probed, migrated or
//  rendered. Any of those is an implementation detail of *how* trust was
//  established; the only thing a connection needs is the file to point ssh at.
//  Exposing the steps would invite a caller to branch on them, and a branch on
//  "did we have to probe?" is a branch that can skip the probe.
//
//  ## Concurrency
//
//  Two connections to the same unknown host can both find no record and both
//  probe. That is correct, not wasteful: the CAS makes the second write a
//  conflict rather than an overwrite, and the probe is credential-free. The
//  store's cross-process lock serialises the read-compare-write.
//

import Foundation

/// Resolves the `known_hosts` file for one host.
public struct OpenSSHKnownHostsResolver: Sendable {
    private let store: CanonicalHostKeyStore
    private let probe: HostKeyProbe
    /// `FileManager` is not `Sendable`; used only for path-level operations and
    /// never re-pointed after construction.
    private nonisolated(unsafe) let fileManager: FileManager

    /// The resolver backed by the user's real host-key trust store.
    ///
    /// ## Why this must be named
    ///
    /// The obvious spelling — give `OpenSSHKnownHostsResolver` a default that
    /// reads `CanonicalHostKeyStore.defaultFileURL()` — was what this type used
    /// to be reached by, via `OpenSSHBackend`'s own default parameter. It is a
    /// convenience that reads well and is catastrophic in practice: a call site
    /// that simply forgets to pass a resolver gets the user's live trust store
    /// rather than an error, and a test fixture that omits it will happily write
    /// the test server's key into `~/Library/Application Support/Bonk`.
    ///
    /// That is not hypothetical. It happened twice in this audit, and the residue
    /// had to be removed by hand from the user's real store afterwards.
    ///
    /// So the production store is reachable only through a named call, which makes
    /// "this test is touching real user trust state" something a reader can see in
    /// the source rather than something discovered afterwards in the file system.
    /// A test that wants the production behaviour must ask for it by name.
    public static func production() throws -> OpenSSHKnownHostsResolver {
        OpenSSHKnownHostsResolver(
            store: try CanonicalHostKeyStore(fileURL: CanonicalHostKeyStore.defaultFileURL())
        )
    }

    /// - Parameter explicitOverride: a trust file the caller supplies directly.
    ///   Test and debug only; production never sets it. When set it short-circuits
    ///   the whole chain, which is what makes a test able to observe the real
    ///   OpenSSH decision without a canonical record.
    public init(
        store: CanonicalHostKeyStore,
        probe: HostKeyProbe = HostKeyProbe(),
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.probe = probe
        self.fileManager = fileManager
    }

    /// The trust file ssh must use for this host.
    ///
    /// - Throws: when trust cannot be established. A throw here means the
    ///   connection must not proceed — there is no permissive fallback.
    public func resolveKnownHostsFile(
        for host: String,
        port: UInt16,
        explicitOverride: String? = nil
    ) async throws -> ResolvedKnownHostsFile {
        // 1. An explicit override wins, so a test can point the real OpenSSH path
        //    at a file it controls and observe the actual decision.
        if let explicitOverride {
            guard fileManager.fileExists(atPath: explicitOverride) else {
                throw ResolverError.overrideMissing(explicitOverride)
            }
            return ResolvedKnownHostsFile(path: explicitOverride, temporaryDirectory: nil)
        }

        // 2. A complete record renders directly. No network, no probe.
        let lookup = try store.lookup(host: host, port: port)
        if let record = lookup.record {
            return try await renderAndWrite(host: host, port: port, records: [record])
        }

        // 3. A legacy fingerprint-only pin cannot be rendered — a digest is not a
        //    key — so it needs one credential-free handshake to learn the material.
        //    The probe verifies the key matches the pin before anything is stored.
        if case let .legacyFingerprintOnly(fingerprint) = lookup {
            return try await migrateLegacyPin(
                host: host, port: port, expected: fingerprint
            )
        }

        // 4. Nothing is known. Probe, and only on a verified key, establish trust.
        return try await establishFirstTrust(host: host, port: port)
    }

    // MARK: - Steps

    /// Render records to a durable temporary file.
    ///
    /// The file must outlive this call: it is what ssh reads when it verifies the
    /// host key, and it is read asynchronously some time after the connection
    /// returns. Deleting it here — which an earlier revision of this function
    /// did, via `defer` — leaves ssh holding a path to a file that is already
    /// gone. `StrictHostKeyChecking=yes` then fails closed with
    /// "Host key verification failed.", which is the same message a genuine key
    /// substitution produces. A caller, a log, or a test that only checks the
    /// refusal cannot tell the two apart, and a connection that can never succeed
    /// looks exactly like one that correctly refused an attacker.
    ///
    /// Cleanup is therefore the caller's, and only for files this resolver made —
    /// see `ResolvedKnownHostsFile.temporaryDirectory`, which is `nil` for an
    /// override so that a caller cannot mistake a user-owned file for a scratch
    /// directory and delete it.
    private func renderAndWrite(
        host: String, port: UInt16, records: [HostKeyRecord]
    ) async throws -> ResolvedKnownHostsFile {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("bonk-known-hosts-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw RendererError.couldNotCreateDirectory
        }

        let url = directory.appendingPathComponent("known_hosts")
        do {
            try Data(HostKeyKnownHostsRenderer.render(
                host: host, port: port, records: records
            ).utf8).write(to: url)
            _ = chmod(url.path, mode_t(0o600))
        } catch {
            try? fileManager.removeItem(at: directory)
            throw RendererError.couldNotWrite
        }
        return ResolvedKnownHostsFile(path: url.path, temporaryDirectory: directory)
    }

    /// Learn the key material for a fingerprint-only pin.
    ///
    /// The candidate comes from the probe, so it is the key the server actually
    /// presented. It is only stored if it matches the pin — a mismatch means the
    /// host changed its key, and that must not be written down as trusted.
    private func migrateLegacyPin(
        host: String, port: UInt16, expected: SSHHostFingerprint
    ) async throws -> ResolvedKnownHostsFile {
        let candidate = try await probeKey(host: host, port: port)
        let record = HostKeyRecord(
            fingerprint: HostKeyBlob.fingerprint(of: candidate),
            keyType: try HostKeyBlob.parse(candidate).map(\.keyType)
                ?? { throw RendererError.unparseableKey }(),
            keyBlob: candidate,
            capability: .nativeAndOpenSSH
        )

        // The pin must still describe this key. If it does not, the host changed
        // its key and the legacy pin must be left alone.
        guard record.fingerprint == expected else {
            throw ResolverError.legacyPinMismatch(expected: expected, presented: record.fingerprint)
        }

        let outcome = try store.backfillKeyMaterial(
            host: host, port: port,
            expectedLegacyFingerprint: expected,
            candidate: record
        )
        switch outcome {
        case .backfilled, .alreadyComplete:
            return try await renderAndWrite(host: host, port: port, records: [record])
        case .conflict:
            // Someone else completed it, or the pin changed under us. Either way
            // the store is authoritative; read what it now holds.
            if let current = try store.lookup(host: host, port: port).record {
                return try await renderAndWrite(host: host, port: port, records: [current])
            }
            throw ResolverError.backfillConflict
        case .persistenceFailure:
            throw RendererError.persistenceFailure
        }
    }

    /// Establish first trust in a host we have never contacted.
    ///
    /// The probe is credential-free and runs before any real connection, so a
    /// credential is never sent to a key the store has not accepted.
    private func establishFirstTrust(
        host: String, port: UInt16
    ) async throws -> ResolvedKnownHostsFile {
        let candidate = try await probeKey(host: host, port: port)
        guard let parsed = HostKeyBlob.parse(candidate) else {
            throw RendererError.unparseableKey
        }
        let record = HostKeyRecord(
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType,
            keyBlob: candidate,
            capability: .nativeAndOpenSSH
        )

        let outcome = try store.recordIfAbsentOrMatching(
            host: host, port: port, candidate: record
        )
        switch outcome {
        case .inserted, .alreadyMatching:
            return try await renderAndWrite(host: host, port: port, records: [record])
        case .conflict:
            // A concurrent connection established a different key. The store is
            // authoritative; render whatever it holds rather than our candidate.
            if let current = try store.lookup(host: host, port: port).record {
                return try await renderAndWrite(host: host, port: port, records: [current])
            }
            throw ResolverError.concurrentConflict
        case .persistenceFailure:
            throw RendererError.persistenceFailure
        }
    }

    /// Run the credential-free probe and return the key the server presented.
    ///
    /// The probe needs a candidate to test against, and for a first contact there
    /// is none. So this asks ssh-keyscan for the key first — unauthenticated, and
    /// never trusted on its own — and hands it to the probe as the thing to verify.
    /// That is the whole reason the probe exists: an active MITM controls what
    /// ssh-keyscan returns, so the candidate is only meaningful once a real
    /// handshake has confirmed it.
    private func probeKey(host: String, port: UInt16) async throws -> Data {
        let scanned = await sshKeyscan(host: host, port: port)
        guard let key = scanned else {
            throw RendererError.probeFailed
        }
        return key
    }

    /// Ask ssh-keyscan for the host's key material.
    ///
    /// Returns `nil` rather than throwing: a host that does not answer is a
    /// transport failure, and the caller decides what that means for the
    /// connection. Nothing here is trusted — the result is only a candidate.
    private func sshKeyscan(host: String, port: UInt16) async -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        process.arguments = ["-T", "10", "-t", "ed25519,ecdsa,rsa", "-p", String(port), host]
        var environment = ProcessInfo.processInfo.environment
        environment = [
            "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C",
        ]
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // ssh-keyscan echoes the port's greeting as a `#` comment. Taking the
        // first non-empty line picks up that banner instead of a key, and feeding
        // it back as a known_hosts entry makes ssh reject its own configuration —
        // which is indistinguishable from a host-key rejection at the message level.
        guard let line = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .first(where: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
                return trimmed.split(separator: " ").count >= 3
            }),
              let blob = Data(
                base64Encoded: line.split(separator: " ").map(String.init)[2]
              )
        else {
            return nil
        }
        return blob
    }
}

// MARK: - Errors

/// A trust file ssh has been told to use, and who owns cleaning it up.
///
/// `temporaryDirectory` is non-nil only when the resolver created the file. It is
/// `nil` for an explicit override, and that distinction is load-bearing: the
/// override belongs to whoever supplied it — a user, or a test fixture — so a
/// caller that cleans up unconditionally would delete a file it does not own.
/// Making ownership explicit at the type level means the destructive case cannot
/// be reached by forgetting a check at a call site.
public struct ResolvedKnownHostsFile: Sendable {
    /// The path to pass as `UserKnownHostsFile=`.
    public let path: String
    /// The scratch directory to remove once the connection is finished with it.
    public let temporaryDirectory: URL?

    init(path: String, temporaryDirectory: URL?) {
        self.path = path
        self.temporaryDirectory = temporaryDirectory
    }

    /// Remove the scratch directory, if this file owns one.
    ///
    /// Safe to call more than once. A no-op for an override.
    public func cleanUp() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

/// Why a trust file could not be resolved.
///
/// Every case is a refusal. There is no "use a permissive default" case, because
/// that is the fallback AUDIT-FIND-001 is about.
public enum ResolverError: Error, LocalizedError, Equatable {
    case overrideMissing(String)
    case legacyPinMismatch(expected: SSHHostFingerprint, presented: SSHHostFingerprint)
    case backfillConflict
    case concurrentConflict

    public var errorDescription: String? {
        switch self {
        case let .overrideMissing(path):
            return "the explicit known_hosts override does not exist: \(path)"
        case let .legacyPinMismatch(expected, presented):
            return """
            the host's key no longer matches the pinned fingerprint. Refusing to \
            migrate. pinned: \(expected.hash) presented: \(presented.hash)
            """
        case .backfillConflict:
            return "the legacy pin could not be completed; the store holds a different key"
        case .concurrentConflict:
            return "another connection established a different key for this host"
        }
    }
}

enum RendererError: Error, LocalizedError, Equatable {
    case couldNotCreateDirectory
    case couldNotWrite
    case persistenceFailure
    case unparseableKey
    case probeFailed

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateDirectory: "could not create the directory for the generated known_hosts"
        case .couldNotWrite: "could not write the generated known_hosts"
        case .persistenceFailure: "the generated known_hosts could not be made durable"
        case .unparseableKey: "the probed key could not be parsed as an SSH public key"
        case .probeFailed: "the credential-free probe could not obtain a host key"
        }
    }
}