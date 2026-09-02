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

    private let lock = NSLock()
    private var activeProcess: OpenSSHProcessTransport?
    private var activePTYSession: PTYSession?
    // Exposed to extensions (+ControlMaster/+Arguments/+Identity/+Askpass)
    let controlPath: String
    let knownHostsPath: String
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

    init(config: SSHConnectionConfig) throws {
        self.config = config
        self.generation = config.generation ?? UUID()
        if config.bypassControlMaster {
            let fresh = "/tmp/bonk-ssh-retry-\(UUID().uuidString).sock"
            controlPath = fresh
            Log.ssh.info("[CONTROLMASTER] bypass enabled, fresh controlPath=\(fresh, privacy: .public)")
        } else {
            controlPath = SocketNaming.controlPath(host: config.host, port: config.port, username: config.username)
        }
        knownHostsPath = try Self.prepareKnownHostsPath()
        try prepareIdentityFiles()
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
    ) throws -> PTYSession {
        let attemptID = UUID().uuidString
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

        let arguments = sshArguments(
            pty: true,
            command: nil,
            additionalOptions: [],
            attemptID: attemptID
        )
        let process = try OpenSSHProcessTransport.spawn(
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

        lock.lock()
        activeProcess = process
        activePTYSession = session
        lock.unlock()

        session.setProcessCleanup { [weak process] in process?.close() }
        session.inputTap = { [weak responder] bytes in responder?.observeInput(bytes) }
        // Secure log: authType / credential source / pw len+fp (no plaintext)
        let authDesc: String
        switch config.authMethod {
        case .password(let p): authDesc = "password(len=\(p.count) fp=\(Self.passwordFingerprint(p)))"
        case .privateKey(let pem): authDesc = "privateKey(pemLen=\(pem.count))"
        case .certificate(let k, let c): authDesc = "certificate(kLen=\(k.count) cLen=\(c.count))"
        case .secureEnclaveKey(let t): authDesc = "secureEnclave(\(t))"
        }
        Log.ssh.info("[OPENSSH-CONFIG] host=\(self.config.host):\(self.config.port) user=\(self.config.username) authType=\(authDesc, privacy: .public) jump=\(self.config.jumpHost?.host ?? "nil", privacy: .public) attempt=\(attemptID, privacy: .public)")
        let ptyTail = OSAllocatedUnfairLock<String>(initialState: "")
        let stderrTail = OSAllocatedUnfairLock<String>(initialState: "")
        // attempt  onExit  11s  SIGHUP  auth
        let capturedAttemptID = attemptID
        let capturedPID = process.processID
        session.startProcess(
            fileDescriptor: process.masterFD,
            onExit: {
                let tail = ptyTail.withLock { String($0.suffix(4096)) }
                let errTail = stderrTail.withLock { String($0.suffix(4096)) }
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
                    case .authentication(let af):
                        let display = SSHErrorMessageParser.explain(tail + "\n" + errTail, host: self.config.host, jumpHost: self.config.jumpHost?.host) ?? af.message
                        Log.ssh.error("[PTY] authFailed: \(display, privacy: .public) rawTail=\(tail.prefix(200), privacy: .public)")
                        if onFailure != nil {
                            onFailure?(.authentication(af))
                        } else {
                            onError?(display)
                        }
                        return
                    case .cancelled:
                        Log.ssh.info("[SSH_FAILURE] type=cancelled backend=openssh")
                        onFailure?(.cancelled)
                        onExit()
                        return
                    case .hostKey(let m):
                        Log.ssh.error("[SSH_FAILURE] type=hostKey backend=openssh msg=\(m, privacy: .public)")
                        onFailure?(.hostKey(m))
                        onError?(m)
                        // hostKey ，，RECOVERY_GATE  block
                        onExit()
                        return
                    case .transport(let tf):
                        Log.ssh.error("[SSH_FAILURE] type=transport backend=openssh msg=\(tf.message, privacy: .public)")
                        onFailure?(typed)
                        // transport  recovery， onExit
                        break
                    case .unknown(let m):
                        Log.ssh.error("[SSH_FAILURE] type=unknown backend=openssh msg=\(m, privacy: .public)")
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
    func executeCommand(_ command: String) async throws -> String {
        let attemptID = UUID().uuidString
        let arguments = sshArguments(pty: false, command: command, additionalOptions: [], attemptID: attemptID)
        let process = try OpenSSHProcessTransport.spawn(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            cols: 160, rows: 50, termType: "xterm-256color"
        )
        defer { process.close() }
        let session = PTYSession()
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

    func runSFTP(
        commands: [String],
        onOutput: (@Sendable (Data) -> Void)? = nil,
        registerProcess: (@Sendable (OpenSSHProcessTransport?) -> Void)? = nil
    ) async throws -> String {
        guard !commands.isEmpty else { throw SSHServiceError.connectionFailed("OpenSSH SFTP command list is empty.") }

        let process = try OpenSSHProcessTransport.spawn(
            executable: "/usr/bin/sftp",
            arguments: sftpArguments(attemptID: UUID().uuidString),
            cols: 160, rows: 50, termType: "xterm-256color"
        )
        let session = PTYSession()
        let rawStream = session.makeRawOutputStream()
        let responder = makeAuthResponder(process: process, allowInteractivePrompt: true)
        registerProcess?(process)
        session.startProcess(fileDescriptor: process.masterFD, onExit: {}, onOutput: { data in responder.observe(data); onOutput?(data) })

        do {
            var output = ""
            var streamIterator = rawStream.makeAsyncIterator()
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
        let patterns = ["couldn't", "permission denied", "denied", "no such file", "not found", "failure", "lost connection", "connection closed", "is a directory", "can't open", "unable to"]
        let lower = text.lowercased()
        return patterns.contains { lower.contains($0) }
    }

    func makeSFTPClient() -> OpenSSHSFTPClient { OpenSSHSFTPClient(backend: self) }

    // MARK: - Forward

    func startPortForward(
        config forward: SSHPortForwardConfiguration,
        onExit: @escaping @Sendable () -> Void
    ) throws -> OpenSSHForwardHandle {
        let forwardOption: String
        switch forward.type {
        case .local: forwardOption = "-L\(forward.localHost):\(forward.localPort):\(forward.remoteHost):\(forward.remotePort)"
        case .remote: forwardOption = "-R\(forward.remoteHost):\(forward.remotePort):\(forward.localHost):\(forward.localPort)"
        case .dynamic: forwardOption = "-D\(forward.localHost):\(forward.localPort)"
        }
        let arguments = sshArguments(pty: false, command: nil, additionalOptions: ["-N", "-o", "ExitOnForwardFailure=yes", forwardOption], attemptID: UUID().uuidString)
        let process = try OpenSSHProcessTransport.spawn(executable: "/usr/bin/ssh", arguments: arguments, cols: 120, rows: 40, termType: "xterm-256color")
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
        if let askpass = jumpAskpassPath { try? FileManager.default.removeItem(atPath: askpass); try? FileManager.default.removeItem(atPath: askpass + ".secret") }
        if let askpass = targetAskpassPath { try? FileManager.default.removeItem(atPath: askpass); try? FileManager.default.removeItem(atPath: askpass + ".secret") }
        targetIdentityFile = nil; targetCertificateFile = nil; jumpIdentityFile = nil; jumpCertificateFile = nil
        jumpAskpassPath = nil; targetAskpassPath = nil
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
