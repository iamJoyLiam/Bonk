//
//  OpenSSHBackend.swift
//  Bonk
//
//  High-level macOS SSH transport built on /usr/bin/ssh.
//  Core: process/PTY/SFTP/forward — helpers live in +Askpass/+ControlMaster/+Identity/+Arguments.
//

#if os(macOS)

import Darwin
import Foundation
import os.log

/// OpenSSH-backed network transport.
///
/// One backend owns one target configuration and one short-lived control
/// socket. Terminal, exec, forwarding, and SFTP commands share that socket,
/// so MFA is normally completed once per target session.
final class OpenSSHBackend: @unchecked Sendable {
    let config: SSHConnectionConfig
    let generation: UUID

    private static let diagnosticTailLimit = 4096

    private let lock = NSLock()
    private var activeProcess: OpenSSHProcessTransport?
    private var activePTYSession: PTYSession?
    // Exposed to extensions (+ControlMaster/+Arguments/+Identity/+Askpass)
    let controlPath: String
    let knownHostsPath: String

    /// An explicit `known_hosts` file that short-circuits the canonical
    /// resolver entirely.
    ///
    /// Test and debug only; production never sets it. When nil — the production
    /// case — every argv path resolves through `knownHostsResolver`, which is
    /// the single place trust is decided. When set, the resolver is bypassed so a
    /// test can point the real OpenSSH path at a file it controls and observe the
    /// actual trust decision rather than a reconstruction of it.
    let knownHostsPathOverride: String?
    var targetIdentityFile: URL?
    var targetCertificateFile: URL?
    var jumpIdentityFile: URL?
    var jumpCertificateFile: URL?
    /// SSH_ASKPASS script for the TARGET password (clean silent auth)
    var targetAskpassPath: String?
    /// SSH_ASKPASS script for Jump host (ProxyCommand)
    var jumpAskpassPath: String?

    /// Called with a password the user typed manually into the terminal once
    /// the server accepted it (stored credential was wrong or missing).
    var onManualPasswordVerified: (@Sendable (String) -> Void)?

    private let spawner: any OpenSSHProcessSpawning

    /// Resolves the `known_hosts` file for a host from the canonical store.
    ///
    /// Injected rather than constructed so a test can supply a store backed by a
    /// temp directory. Production passes the real canonical store.
    let knownHostsResolver: OpenSSHKnownHostsResolver

    /// Scratch trust files this backend created and must remove when it closes.
    ///
    /// ssh reads `UserKnownHostsFile` asynchronously, some time after the
    /// connection returns, so the file has to outlive the resolve call. That
    /// makes the resolver unable to clean up after itself, and hands ownership
    /// here — which is why this is a list rather than a single optional: a
    /// connection with a jump host resolves two files, and a reconnecting
    /// backend resolves one per attempt.
    private var ownedTrustFiles: [ResolvedKnownHostsFile] = []

    /// Trust files already resolved for this backend, keyed by `host:port`.
    ///
    /// `OpenSSHSFTPClient` spawns a fresh `/usr/bin/sftp` for **every** command
    /// batch, and each one goes through `runSFTP`, which resolves trust first.
    /// Without this cache a single folder listing costs an extra temp directory,
    /// file write and `chmod` — and the owned-file list grew for the life of the
    /// session, one entry per operation, cleaned up only at `close()`.
    ///
    /// Caching the *rendered file* is safe and does not weaken verification: the
    /// file is static, and `ssh` still checks the presented key against it on every
    /// connection. A substituted key still fails exactly as it would against a
    /// freshly rendered file. What the cache removes is redundant work, not a check.
    ///
    /// Known limitation: if the canonical record for a host changes while this
    /// backend is alive, the cached file is stale until `close()`. Nothing can
    /// currently change it — the re-trust/pin-removal path is still AUDIT-OBS-003
    /// — but that is the condition under which this cache would need invalidating.
    private var resolvedTrustCache: [String: ResolvedKnownHostsFile] = [:]

    /// Reusable `sftp` process for short control commands (`ls`, `mkdir`, …).
    ///
    /// Without it every folder open costs a full SSH connection. Only control
    /// commands use it — transfers keep a dedicated process so cancellation and
    /// progress parsing are unaffected. See `OpenSSFTSession`.
    private var pooledSFTPSession: OpenSSFTSession?

    /// Resolve a trust file, reusing this backend's earlier result for the host.
    private func resolvedTrustFile(
        host: String, port: UInt16
    ) async throws -> ResolvedKnownHostsFile {
        let key = "\(host):\(port)"
        if let cached = resolvedTrustCache[key] { return cached }
        let resolved = try await knownHostsResolver.resolveKnownHostsFile(
            for: host, port: port,
            explicitOverride: knownHostsPathOverride
        )
        adopt(resolved)
        resolvedTrustCache[key] = resolved
        return resolved
    }

    /// Take ownership of a generated trust file so `close()` removes it.
    private func adopt(_ resolved: ResolvedKnownHostsFile) {
        guard resolved.temporaryDirectory != nil else { return }
        ownedTrustFiles.append(resolved)
    }

    /// Remove every scratch trust file this backend created.
    ///
    /// Only ever removes directories the resolver created; an override is not
    /// tracked, so a user-supplied file cannot be deleted from here.
    private func cleanUpOwnedTrustFiles() {
        for file in ownedTrustFiles { file.cleanUp() }
        ownedTrustFiles.removeAll()
        resolvedTrustCache.removeAll()
    }

    /// - Parameter knownHostsPathOverride: Where ssh records and checks host keys
    ///   on this transport. `nil` keeps production behaviour exactly as it was:
    ///   the app-support file created by `prepareKnownHostsPath()`. It exists as a
    ///   parameter so a test can point the trust store at a temporary file and
    ///   observe the real trust decision, rather than writing host keys into a
    ///   real, persistent, user-visible file. It changes no other behaviour — the
    ///   argv is still built by `Arguments.swift` and still launched through the
    ///   spawn seam.
    /// - Parameter knownHostsResolver: Required, and required to be named. Pass
    ///   `OpenSSHKnownHostsResolver.production()` in production, or one built over
    ///   a temporary `CanonicalHostKeyStore` in a test. See `production()` for why
    ///   there is no default.
    init(
        config: SSHConnectionConfig,
        spawner: any OpenSSHProcessSpawning = DefaultOpenSSHProcessSpawner(),
        knownHostsPathOverride: String? = nil,
        knownHostsResolver: OpenSSHKnownHostsResolver
    ) throws {
        self.spawner = spawner
        self.config = config
        self.generation = config.generation ?? UUID()
        if config.bypassControlMaster {
            let fresh = "/tmp/bonk-ssh-retry-\(UUID().uuidString).sock"
            controlPath = fresh
            Log.ssh.info("[CONTROLMASTER] bypass enabled, fresh controlPath=\(fresh, privacy: .public)")
        } else {
            controlPath = SocketNaming.controlPath(host: config.host, port: config.port, username: config.username)
        }
        // The resolver is always present; the override only short-circuits it.
        // A backend without a resolver could not establish trust at all, which
        // is the fail-closed behaviour AUDIT-FIND-001 requires.
        //
        // There is no default. It used to be `knownHostsResolver ?? <production
        // store>`, which meant any construction site that forgot to pass one —
        // including test fixtures — silently resolved against the user's real
        // host-key records in Application Support. Two suites did exactly that,
        // and the first-contact branch wrote the test server's key into the user's
        // trust store. A default here is a loaded gun pointed at user data, so the
        // production store must now be named explicitly via
        // `OpenSSHKnownHostsResolver.production()`.
        self.knownHostsResolver = try knownHostsResolver
        self.knownHostsPathOverride = knownHostsPathOverride
        knownHostsPath = try knownHostsPathOverride ?? Self.prepareKnownHostsPath()
        try prepareIdentityFiles()
    }

    /// The default location of the canonical host-key store.
    ///
    /// Reachable only through `OpenSSHKnownHostsResolver.production()`.
    fileprivate static func defaultStoreURL() throws -> URL {
        try CanonicalHostKeyStore.defaultFileURL()
    }

    // MARK: - Terminal

    /// Open an interactive terminal.
    /// Typed failure path: `onFailure` receives `SSHFailure` for Recovery gate; `onError` kept for legacy UI string.
    func openPTY(
        cols: Int,
        rows: Int,
        termType: String,
        onExit: @escaping @Sendable () -> Void,
        onError: (@Sendable (String) -> Void)? = nil,
        onFailure: (@Sendable (SSHFailure) -> Void)? = nil
    ) async throws -> PTYSession {
        let attemptID = UUID().uuidString

        // Resolve the trust file before any credential-bearing work begins.
        // A host we cannot vouch for must fail closed here, not after a
        // password has already been offered.
        let resolvedKnownHosts = try await resolvedTrustFile(host: config.host, port: config.port)
        // Explicit if-let rather than `Optional.map`: the closure both throws and
        // awaits, and `map` can carry neither without erasing the error.
        //
        // Each hop gets its OWN trust record. Reusing the target's pin for a jump
        // host is precisely the divergence AUDIT-FIND-001 describes.
        var resolvedJumpKnownHosts: ResolvedKnownHostsFile?
        if let jump = config.jumpHost {
            // No override here, deliberately. An override names one file, and
            // handing it to the jump hop would point the two hops at the *same*
            // trust store — so the target's key would be checked against the
            // jump host's pin and vice versa. The comment above this block used
            // to claim each hop gets its own record while the code passed the
            // target's override straight through. An override is a test/debug
            // affordance for a single-host connection; it has no meaning for a
            // second host it was never written about.
            resolvedJumpKnownHosts = try await resolvedTrustFile(
                host: jump.host, port: jump.port
            )
        }

        var environment: [String: String] = [:]
        // PTY  responder TTY hook  +  SUCCESS，askpass  PTY  executeCommand/sftp
        let useAskPassForPTY = false
        if let targetPassword = password(from: config.authMethod), useAskPassForPTY {
            let askpassPath = writeAskPassScript(
                targetPassword,
                attemptID: attemptID,
                host: config.host,
                username: config.username
            )
            targetAskpassPath = askpassPath
            environment["SSH_ASKPASS"] = askpassPath
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"
            // ： cat secret + printf ， stdoutlogger  syslog
            if let scriptData = try? Data(contentsOf: URL(fileURLWithPath: askpassPath)),
               let scriptText = String(data: scriptData, encoding: .utf8) {
                let lines = scriptText.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
                let isCatVersion = scriptText.contains("cat \"") && scriptText.contains("printf '\\n'")
                let isInlineVersion = scriptText.contains("printf '%s\\n'")
                if !(isCatVersion || isInlineVersion) || !(lines.count == 3 || lines.count == 4) {
                    Log.ssh.error("[ASKPASS] script polluted attempt=\(attemptID, privacy: .public) lines=\(lines.count) text=\(scriptText.prefix(200), privacy: .public)")
                } else {
                    Log.ssh.info("[ASKPASS] script verified clean attempt=\(attemptID, privacy: .public) catVersion=\(isCatVersion)")
                }
            }
            Log.ssh.info("[ASKPASS] attempt=\(attemptID) script=\(askpassPath) host=\(self.config.host) username=\(self.config.username) passwordLength=\(targetPassword.count) fp=\(Self.passwordFingerprint(targetPassword)) DISPLAY=:0 SSH_ASKPASS_REQUIRE=force")
        }

        let arguments = try await sshArguments(
                pty: true,
                command: nil,
                additionalOptions: [],
                attemptID: attemptID,
                knownHostsPath: resolvedKnownHosts.path,
                jumpKnownHostsPath: resolvedJumpKnownHosts?.path
            )
        let process = try spawner.spawn(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            cols: cols,
            rows: rows,
            termType: termType,
            environment: environment
        )
        Log.ssh.info("[CONNECT] attempt=\(attemptID) processPID=\(process.processID) host=\(self.config.host):\(self.config.port) username=\(self.config.username) gen=\(self.generation.uuidString.prefix(8))")
        let session = PTYSession()
        session.generation = generation
        let responder = makeAuthResponder(process: process, allowInteractivePrompt: true)
        responder.onManualPasswordVerified = { [weak self] password in
            self?.onManualPasswordVerified?(password)
        }

        // Scoped rather than bare lock/unlock: the function is now `async`, and a bare
        // `lock()` in an async body is a diagnostic about holding a mutex across a
        // suspension point. This region contains no `await`, and scoping it keeps
        // that true by construction.
        lock.withLock {
            activeProcess = process
            activePTYSession = session
        }

        session.setProcessCleanup { [weak process] in process?.close() }
        session.inputTap = { [weak responder] bytes in responder?.observeInput(bytes) }
        // Secure log: authType / credential source / pw len+fp (no plaintext)
        let authDesc: String
        switch config.authMethod {
        case .password(let password): authDesc = "password(len=\(password.count) fp=\(Self.passwordFingerprint(password)))"
        case .privateKey(let pem): authDesc = "privateKey(pemLen=\(pem.count))"
        case .certificate(let keyData, let certificateData): authDesc = "certificate(kLen=\(keyData.count) cLen=\(certificateData.count))"
        case .secureEnclaveKey(let tag): authDesc = "secureEnclave(\(tag))"
        }
        Log.ssh.info("[OPENSSH-CONFIG] host=\(self.config.host):\(self.config.port) user=\(self.config.username) authType=\(authDesc, privacy: .public) jump=\(self.config.jumpHost?.host ?? "nil", privacy: .public) attempt=\(attemptID, privacy: .public)")
        let ptyTail = OSAllocatedUnfairLock(
            initialState: BoundedTextTail(limit: Self.diagnosticTailLimit)
        )
        let stderrTail = OSAllocatedUnfairLock(
            initialState: BoundedTextTail(limit: Self.diagnosticTailLimit)
        )
        // attempt  onExit  11s  SIGHUP  auth
        let capturedAttemptID = attemptID
        let capturedPID = process.processID
        session.startProcess(
            fileDescriptor: process.masterFD,
            onExit: { [weak self, weak session] in
                guard let self, let session else { return }
                let tail = ptyTail.withLock { $0.value }
                let errTail = stderrTail.withLock { $0.value }
                // wasUserClosed  PTYSession.userClosedBoxclose  true  onUnexpectedClose ，
                let wasClosed = session.isClosed
                // exitStatus， 1； waitForExit  400ms
                // ， reap ， 1 ， handleTypedFailure  wasClosed second
                let status: Int32 = 1
                let typed: SSHFailure? = SSHFailureClassifier.classify(tail: tail, stderr: errTail, terminationStatus: status, wasUserClosed: wasClosed)
                Log.ssh.info("[PTY_EXIT] attempt=\(capturedAttemptID, privacy: .public) pid=\(capturedPID) wasClosed=\(wasClosed) status=\(status) tailPrefix=\(tail.prefix(80), privacy: .public)")
                let legacy: SSHProcessFailure? = SSHProcessFailureClassifier.classify(tail: tail, stderr: errTail, terminationStatus: status, wasUserClosed: false)
                if let typed {
                    Log.ssh.info("[SSH_FAILURE] type=\(typed.typeString, privacy: .public) backend=openssh host=\(self.config.host, privacy: .public)")
                    switch typed {
                    case .authentication(let authFailure):
                        let display = SSHErrorMessageParser.explain(tail + "\n" + errTail, host: self.config.host, jumpHost: self.config.jumpHost?.host) ?? authFailure.message
                        Log.ssh.error("[PTY] authFailed: \(display, privacy: .public) rawTail=\(tail.prefix(200), privacy: .public)")
                        if onFailure != nil {
                            onFailure?(.authentication(authFailure))
                        } else {
                            onError?(display)
                        }
                        return
                    case .cancelled:
                        Log.ssh.info("[SSH_FAILURE] type=cancelled backend=openssh")
                        onFailure?(.cancelled)
                        onExit()
                        return
                    case .hostKey(let hostKeyMessage):
                        Log.ssh.error("[SSH_FAILURE] type=hostKey backend=openssh msg=\(hostKeyMessage, privacy: .public)")
                        onFailure?(.hostKey(hostKeyMessage))
                        onError?(hostKeyMessage)
                        // hostKey ，，RECOVERY_GATE  block
                        onExit()
                        return
                    case .transport(let transportFailure):
                        Log.ssh.error("[SSH_FAILURE] type=transport backend=openssh msg=\(transportFailure.message, privacy: .public)")
                        onFailure?(typed)
                        // transport  recovery， onExit
                        break
                    case .unknown(let unknownMessage):
                        Log.ssh.error("[SSH_FAILURE] type=unknown backend=openssh msg=\(unknownMessage, privacy: .public)")
                        onFailure?(typed)
                        break
                    }
                } else if let legacy = legacy {
                    // fallback to legacy classifier for any edge missed by typed
                    switch legacy {
                    case .authentication(let msg):
                        let typedAF: SSHFailure = .authentication(.permissionDenied(msg))
                        Log.ssh.info("[SSH_FAILURE] type=authentication backend=openssh (legacy)")
                        let display = SSHErrorMessageParser.explain(tail + "\n" + errTail, host: self.config.host, jumpHost: self.config.jumpHost?.host) ?? msg
                        onFailure?(typedAF)
                        onError?(display)
                        return
                    case .cancelled:
                        onFailure?(.cancelled)
                        onExit()
                        return
                    default: break
                    }
                }
                if let message = Self.extractConnectionError(from: tail) {
                    Log.ssh.error("[PTY] Session failed (fallback): \(message, privacy: .public)")
                    onError?(SSHErrorMessageParser.explain(tail, host: self.config.host, jumpHost: self.config.jumpHost?.host) ?? message)
                } else if !tail.isEmpty {
                    Log.ssh.error("[PTY] Session exited. Raw tail:\n\(tail, privacy: .public)")
                }
                onExit()
            },
            onOutput: { data in
                responder.observe(data)
                let str = String(data: data, encoding: .utf8) ?? ""
                ptyTail.withLock { $0.append(str) }
                stderrTail.withLock { $0.append(str) }
            }
        )
        return session
    }

    // MARK: - Exec

    /// Execute one command with clean output.
    func executeCommand(
        _ command: String,
        registerHandle: CommandHandleRegistration? = nil
    ) async throws -> String {
        let attemptID = UUID().uuidString
        let resolvedKnownHosts = try await resolvedTrustFile(host: config.host, port: config.port)
        // Explicit if-let rather than `Optional.map`: the closure both throws and
        // awaits, and `map` can carry neither without erasing the error.
        //
        // Each hop gets its OWN trust record. Reusing the target's pin for a jump
        // host is precisely the divergence AUDIT-FIND-001 describes.
        var resolvedJumpKnownHosts: ResolvedKnownHostsFile?
        if let jump = config.jumpHost {
            // No override here, deliberately. An override names one file, and
            // handing it to the jump hop would point the two hops at the *same*
            // trust store — so the target's key would be checked against the
            // jump host's pin and vice versa. The comment above this block used
            // to claim each hop gets its own record while the code passed the
            // target's override straight through. An override is a test/debug
            // affordance for a single-host connection; it has no meaning for a
            // second host it was never written about.
            resolvedJumpKnownHosts = try await resolvedTrustFile(
                host: jump.host, port: jump.port
            )
        }
        let arguments = sshArguments(
            pty: false, command: command, additionalOptions: [], attemptID: attemptID,
            knownHostsPath: resolvedKnownHosts.path,
            jumpKnownHostsPath: resolvedJumpKnownHosts?.path
        )
        let process = try spawner.spawn(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            cols: 160, rows: 50, termType: "xterm-256color", environment: [:]
        )
        defer { process.close() }
        let session = PTYSession()
        let handle = ProcessCommandExecutionHandle(process: process, session: session)
        await registerHandle?(handle)
        let rawStream = session.makeRawOutputStream()
        let responder = makeAuthResponder(process: process, allowInteractivePrompt: true)
        session.startProcess(fileDescriptor: process.masterFD, onExit: {}, onOutput: responder.observe)

        var output = ""
        for await chunk in rawStream { output.append(chunk) }
        let status = await process.waitForExit()
        session.close()
        guard status == 0 else {
            let detail = Self.cleanCommandOutput(output)
            throw SSHServiceError.connectionFailed(
                detail.isEmpty ? "OpenSSH command exited with status \(status)." :
                    (SSHErrorMessageParser.explain(detail, host: config.host, jumpHost: config.jumpHost?.host) ?? detail)
            )
        }
        return Self.cleanCommandOutput(output)
    }

    // MARK: - SFTP

    /// Run short control commands on a shared `sftp` process.
    ///
    /// Falls back to `runSFTP` (its own process) for anything that is not a
    /// control command, and whenever the pooled session is unavailable. The
    /// fallback is deliberate: a pooling failure must degrade to the old, slower,
    /// correct behaviour rather than fail the operation.
    func runSFTPControlCommands(_ commands: [String]) async throws -> String {
        guard !commands.isEmpty else { return "" }
        guard Self.isControlCommand(commands) else {
            return try await runSFTP(commands: commands)
        }

        if let pooled = pooledSFTPSession {
            do {
                return try await pooled.run(commands)
            } catch {
                // The pooled process is suspect; drop it and retry once on a
                // fresh one, so a single hiccup does not fail a directory listing.
                pooled.terminate()
                pooledSFTPSession = nil
            }
        }

        let resolvedKnownHosts = try await resolvedTrustFile(host: config.host, port: config.port)
        var resolvedJumpKnownHosts: ResolvedKnownHostsFile?
        if let jump = config.jumpHost {
            resolvedJumpKnownHosts = try await resolvedTrustFile(host: jump.host, port: jump.port)
        }
        let arguments = sftpArguments(
            attemptID: UUID().uuidString,
            knownHostsPath: resolvedKnownHosts.path,
            jumpKnownHostsPath: resolvedJumpKnownHosts?.path
        )
        // The auth responder is what types the password when `sftp` prompts on
        // its PTY. Without it the session sits at the prompt forever and every
        // listing times out. It is built here because it needs the transport, and
        // the transport does not exist until the session spawns it.
        let session = try await OpenSSFTSession.start(
            spawner: spawner,
            arguments: arguments,
            makeOutputObserver: { [weak self] transport in
                guard let self else { return { _ in } }
                let responder = self.makeAuthResponder(
                    process: transport, allowInteractivePrompt: true
                )
                return { data in responder.observe(data) }
            }
        )
        let output = try await session.run(commands)
        pooledSFTPSession = session
        return output
    }

    /// Whether a batch is safe to share one long-lived process for.
    ///
    /// Deliberately conservative. `get`/`put` are excluded because a transfer can
    /// run for minutes and would block every other operation behind it, and its
    /// progress output and cancellation are tied to its own process.
    private static func isControlCommand(_ commands: [String]) -> Bool {
        let controlPrefixes = ["pwd", "ls", "cd", "mkdir", "rm ", "rmdir", "rename", "reget "]
        return commands.allSatisfy { command in
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            // `reget` resumes a transfer, so it is treated as a transfer.
            if trimmed.hasPrefix("get") || trimmed.hasPrefix("put") { return false }
            return controlPrefixes.contains { trimmed.hasPrefix($0) }
        }
    }

    func runSFTP(
        commands: [String],
        onOutput: (@Sendable (Data) -> Void)? = nil,
        registerProcess: (@Sendable (OpenSSHProcessTransport?) -> Void)? = nil
    ) async throws -> String {
        guard !commands.isEmpty else { throw SSHServiceError.connectionFailed("OpenSSH SFTP command list is empty.") }

        let resolvedKnownHosts = try await resolvedTrustFile(host: config.host, port: config.port)
        // Explicit if-let rather than `Optional.map`: the closure both throws and
        // awaits, and `map` can carry neither without erasing the error.
        //
        // Each hop gets its OWN trust record. Reusing the target's pin for a jump
        // host is precisely the divergence AUDIT-FIND-001 describes.
        var resolvedJumpKnownHosts: ResolvedKnownHostsFile?
        if let jump = config.jumpHost {
            // No override here, deliberately. An override names one file, and
            // handing it to the jump hop would point the two hops at the *same*
            // trust store — so the target's key would be checked against the
            // jump host's pin and vice versa. The comment above this block used
            // to claim each hop gets its own record while the code passed the
            // target's override straight through. An override is a test/debug
            // affordance for a single-host connection; it has no meaning for a
            // second host it was never written about.
            resolvedJumpKnownHosts = try await resolvedTrustFile(
                host: jump.host, port: jump.port
            )
        }

        let process = try spawner.spawn(
            executable: "/usr/bin/sftp",
            arguments: sftpArguments(
                attemptID: UUID().uuidString,
                knownHostsPath: resolvedKnownHosts.path,
                jumpKnownHostsPath: resolvedJumpKnownHosts?.path
            ),
            cols: 160, rows: 50, termType: "xterm-256color", environment: [:]
        )
        let session = PTYSession()
        let rawStream = session.makeRawOutputStream()
        let responder = makeAuthResponder(process: process, allowInteractivePrompt: true)
        registerProcess?(process)
        session.startProcess(fileDescriptor: process.masterFD, onExit: {}, onOutput: { data in responder.observe(data); onOutput?(data) })

        do {
            var output = ""
            var streamIterator = rawStream.makeAsyncIterator()
            // Wait for the initial `sftp>` prompt before writing anything:
            // commands sent while sftp is still connecting (cold
            // ControlMaster, DNS, MFA) are silently lost. Bounded so a hung
            // child fails fast instead of hanging forever.
            var readyBuffer = ""
            let readyDeadline = Date().addingTimeInterval(120)
            while !Self.sftpPromptAppeared(in: readyBuffer) {
                if Date() > readyDeadline {
                    throw SSHServiceError.connectionFailed("OpenSSH SFTP session not ready.")
                }
                guard let chunk = await streamIterator.next() else { break }
                readyBuffer.append(chunk); output.append(chunk)
            }
            for command in commands {
                try process.write(Data((command + "\n").utf8))
                var chunkBuffer = ""
                while true {
                    guard let chunk = await streamIterator.next() else { break }
                    chunkBuffer.append(chunk); output.append(chunk)
                    if Self.sftpPromptAppeared(in: chunkBuffer) { break }
                    if chunkBuffer.count > 128 * 1024 { break }
                }
                let cleaned = Self.cleanCommandOutput(chunkBuffer)
                if Self.sftpOutputContainsError(cleaned) { throw SSHServiceError.connectionFailed(cleaned) }
            }
            try? process.write(Data("quit\n".utf8))
            while let chunk = await streamIterator.next() { output.append(chunk) }
            let status = await process.waitForExit()
            session.close(); process.close(); registerProcess?(nil)
            guard status == 0 else {
                let detail = Self.cleanCommandOutput(output)
                throw SSHServiceError.connectionFailed(
                    detail.isEmpty ? "OpenSSH SFTP exited with status \(status)." :
                        (SSHErrorMessageParser.explain(detail, host: config.host, jumpHost: config.jumpHost?.host) ?? detail)
                )
            }
            return Self.cleanCommandOutput(output)
        } catch {
            registerProcess?(nil); session.close(); process.close(); throw error
        }
    }

    private static func sftpPromptAppeared(in text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: #"\u001B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        return stripped.hasSuffix("sftp> ") || stripped.hasSuffix("sftp>")
    }

    private static func sftpOutputContainsError(_ text: String) -> Bool {
        let patterns = ["couldn't", "permission denied", "denied", "no such file", "not found", "failure", "lost connection", "connection closed", "is a directory", "can't open", "unable to", "invalid flag", "unknown command", "bad path"]
        let lower = text.lowercased()
        return patterns.contains { lower.contains($0) }
    }

    func makeSFTPClient() -> OpenSSHSFTPClient { OpenSSHSFTPClient(backend: self) }

    // MARK: - Forward

    func startPortForward(
        config forward: SSHPortForwardConfiguration,
        onExit: @escaping @Sendable () -> Void
    ) async throws -> OpenSSHForwardHandle {
        let forwardOption: String
        switch forward.type {
        case .local: forwardOption = "-L\(forward.localHost):\(forward.localPort):\(forward.remoteHost):\(forward.remotePort)"
        case .remote: forwardOption = "-R\(forward.remoteHost):\(forward.remotePort):\(forward.localHost):\(forward.localPort)"
        case .dynamic: forwardOption = "-D\(forward.localHost):\(forward.localPort)"
        }
        let resolvedKnownHosts = try await resolvedTrustFile(host: config.host, port: config.port)
        // Explicit if-let rather than `Optional.map`: the closure both throws and
        // awaits, and `map` can carry neither without erasing the error.
        //
        // Each hop gets its OWN trust record. Reusing the target's pin for a jump
        // host is precisely the divergence AUDIT-FIND-001 describes.
        var resolvedJumpKnownHosts: ResolvedKnownHostsFile?
        if let jump = config.jumpHost {
            // No override here, deliberately. An override names one file, and
            // handing it to the jump hop would point the two hops at the *same*
            // trust store — so the target's key would be checked against the
            // jump host's pin and vice versa. The comment above this block used
            // to claim each hop gets its own record while the code passed the
            // target's override straight through. An override is a test/debug
            // affordance for a single-host connection; it has no meaning for a
            // second host it was never written about.
            resolvedJumpKnownHosts = try await resolvedTrustFile(
                host: jump.host, port: jump.port
            )
        }
        let arguments = sshArguments(
            pty: false, command: nil,
            additionalOptions: ["-N", "-o", "ExitOnForwardFailure=yes", forwardOption],
            attemptID: UUID().uuidString,
            knownHostsPath: resolvedKnownHosts.path,
            jumpKnownHostsPath: resolvedJumpKnownHosts?.path
        )
        let process = try spawner.spawn(executable: "/usr/bin/ssh", arguments: arguments, cols: 120, rows: 40, termType: "xterm-256color", environment: [:])
        let session = PTYSession()
        let responder = makeAuthResponder(process: process, allowInteractivePrompt: true)
        session.startProcess(fileDescriptor: process.masterFD, onExit: onExit, onOutput: responder.observe)
        return OpenSSHForwardHandle(process: process, session: session)
    }

    // MARK: - Auth

    func authCredentials() -> [OpenSSHPasswordCredential] {
        var credentials: [OpenSSHPasswordCredential] = []
        if let jumpHost = config.jumpHost, let jumpPassword = password(from: jumpHost.authMethod) {
            credentials.append(OpenSSHPasswordCredential(username: jumpHost.username, host: jumpHost.host, password: jumpPassword))
        }
        if let targetPassword = password(from: config.authMethod) {
            credentials.append(OpenSSHPasswordCredential(username: config.username, host: config.host, password: targetPassword))
        }
        return credentials
    }

    func writeToProcess(_ process: OpenSSHProcessTransport, _ data: Data) { try? process.write(data) }

    func close() {
        lock.lock()
        let process = activeProcess
        let session = activePTYSession
        activeProcess = nil; activePTYSession = nil
        lock.unlock()
        session?.close(); process?.close()
        closeControlMaster()
        for file in ([targetIdentityFile, targetCertificateFile, jumpIdentityFile, jumpCertificateFile] as [URL?]).compactMap(\.self) {
            try? FileManager.default.removeItem(at: file)
        }
        // Askpass pair: the script and the secret it reads. Both are removed
        // on every close path, success or failure. A leftover plaintext
        // secret here is swept on the next launch by SecureTempFileSweeper.
        if let askpass = jumpAskpassPath { Self.removeAskpassPair(at: askpass) }
        if let askpass = targetAskpassPath { Self.removeAskpassPair(at: askpass) }
        targetIdentityFile = nil; targetCertificateFile = nil; jumpIdentityFile = nil; jumpCertificateFile = nil
        jumpAskpassPath = nil; targetAskpassPath = nil
        cleanUpOwnedTrustFiles()
        pooledSFTPSession?.terminate()
        pooledSFTPSession = nil
    }

    // MARK: - Helpers (kept here; arguments/identity/askpass/control in extensions)

    func makeAuthResponder(process: OpenSSHProcessTransport, allowInteractivePrompt: Bool, includePassword: Bool = true) -> OpenSSHAuthPromptResponder {
        var authUserHosts: [String] = []
        if let jumpHost = config.jumpHost { authUserHosts.append("\(jumpHost.username)@\(jumpHost.host)") }
        authUserHosts.append("\(config.username)@\(config.host)")
        let effectiveCreds = includePassword ? authCredentials() : [] // askpass ，stdin  password，
        return OpenSSHAuthPromptResponder(
            credentials: effectiveCreds,
            authUserHosts: authUserHosts,
            allowInteractivePrompt: allowInteractivePrompt,
            allowUnscopedPassword: allowInteractivePrompt && config.jumpHost == nil,
            write: { [weak self, weak process] data in
                guard let self, let process else { return }
                self.writeToProcess(process, data)
            }
        )
    }

    func password(from authMethod: SSHAuthMethod?) -> String? {
        guard case let .password(value) = authMethod else { return nil }
        return value
    }

    static func cleanCommandOutput(_ output: String) -> String {
        output.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractConnectionError(from output: String) -> String? {
        let lower = output.lowercased()
        guard lower.contains("denied") || lower.contains("refused") || lower.contains("timed out") || lower.contains("prohibited")
            || lower.contains("no route") || lower.contains("unreachable") || lower.contains("closed")
            || lower.contains("host key") || lower.contains("negotiate") || lower.contains("authentication")
            || lower.contains("exchange_identification") || lower.contains("no such file") || lower.contains("not found")
            || lower.contains("could not resolve") || lower.contains("failed to allocate") || lower.contains("connection reset")
            || lower.contains("lost connection") || lower.contains("kex_exchange")
        else { return nil }
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.lowercased().hasPrefix("debug1:") || line.lowercased().hasPrefix("debug2:") || line.lowercased().hasPrefix("debug3:") { continue }
            let lowercasedLine = line.lowercased()
            let keywords = ["permission denied", "denied", "refused", "timed out", "administratively prohibited", "no route to host", "unreachable", "connection closed", "closed by remote", "host key verification failed", "unable to negotiate", "too many authentication failures", "ssh_exchange_identification", "no supported authentication methods", "connection reset", "lost connection", "could not resolve hostname", "failed to allocate pty", "kex_exchange_identification", "no such file", "not found"]
            if keywords.contains(where: { lowercasedLine.contains($0) }) { return line }
        }
        return nil
    }
}

#endif
