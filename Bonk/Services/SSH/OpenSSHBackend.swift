//
//  OpenSSHBackend.swift
//  Bonk
//
//  High-level macOS SSH transport built on /usr/bin/ssh.
//

#if os(macOS)

import Darwin
import Crypto
import Foundation
import os.log

/// OpenSSH-backed network transport.
///
/// One backend owns one target configuration and one short-lived control
/// socket. Terminal, exec, forwarding, and SFTP commands share that socket,
/// so MFA is normally completed once per target session.
final class OpenSSHBackend: @unchecked Sendable {
    let config: SSHConnectionConfig

    private let lock = NSLock()
    private var activeProcess: OpenSSHProcessTransport?
    private var activePTYSession: PTYSession?
    private let controlPath: String
    private let knownHostsPath: String
    private var targetIdentityFile: URL?
    private var targetCertificateFile: URL?
    private var jumpIdentityFile: URL?
    private var jumpCertificateFile: URL?

    /// Called with a password the user typed manually into the terminal once
    /// the server accepted it (stored credential was wrong or missing).
    var onManualPasswordVerified: (@Sendable (String) -> Void)?

    init(config: SSHConnectionConfig) throws {
        self.config = config
        // A STABLE per-host ControlPath is what makes ControlMaster reusable
        // and reclaimable. A random path per connection created a brand-new
        // mux every time and orphaned mux processes (holding PTYs) whenever
        // a client exited abnormally — eventually exhausting the PTY limit.
        let safeUser = config.username.replacingOccurrences(of: "/", with: "_")
        let safeHost = config.host.replacingOccurrences(of: "/", with: "_")
        // Include jump host and auth-method fingerprints: two tabs to the same
        // host must NOT share a ControlMaster when they route through
        // different jump hosts or authenticate differently — the second
        // connection would silently use the first one's credentials, and
        // closing one tab would kill the other's session via `ssh -O exit`.
        let jumpTag: String = if let jump = config.jumpHost {
            "via-\(jump.username.replacingOccurrences(of: "/", with: "_"))-\(jump.host.replacingOccurrences(of: "/", with: "_"))-\(jump.port)"
        } else {
            "direct"
        }
        let authTag: String = switch config.authMethod {
        case .password: "pw"
        case .privateKey: "key"
        case .certificate: "cert"
        case .secureEnclaveKey: "enclave"
        }
        controlPath = "/tmp/bonk-ssh-\(safeUser)-\(safeHost)-\(config.port)-\(jumpTag)-\(authTag).sock"
        knownHostsPath = try Self.prepareKnownHostsPath()
        try prepareIdentityFiles()
    }

    /// Kill leftover `bonk-ssh` mux processes and stale control sockets.
    /// Called once at app launch, when no live connections exist. A mux that
    /// survives a crashed/killed client holds its PTY open forever, so this
    /// reclaims those PTYs for future sessions.
    ///
    /// SIGKILL (-9) is intentional: SIGTERM proved unreliable here — after a
    /// force-quit of the app, leftover ssh -tt children (session leaders)
    /// survived a plain pkill and kept consuming PTYs until macOS refused to
    /// allocate new ones (openpty ENXIO, errno 6). At launch there are no
    /// live Bonk connections, so killing every matching process is safe.
    static func cleanupOrphanedMuxes() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "pkill -9 -f 'bonk-ssh-.*\\.sock' 2>/dev/null; "
                + "rm -f /tmp/bonk-ssh-*.sock 2>/dev/null",
        ]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
    }

    /// Open an interactive terminal.
    func openPTY(
        cols: Int,
        rows: Int,
        termType: String,
        onExit: @escaping @Sendable () -> Void,
        onError: (@Sendable (String) -> Void)? = nil
    ) throws -> PTYSession {
        let arguments = sshArguments(
            pty: true,
            command: nil,
            additionalOptions: []
        )
        let process = try OpenSSHProcessTransport.spawn(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            cols: cols,
            rows: rows,
            termType: termType
        )
        let session = PTYSession()
        let responder = makeAuthResponder(process: process, allowInteractivePrompt: false)
        responder.onManualPasswordVerified = { [weak self] password in
            self?.onManualPasswordVerified?(password)
        }
        // After an automatic password reply, erase the on-screen "password:"
        // prompt line so authentication leaves no residue.
        responder.onAutoReply = { [weak session] in
            session?.queuePromptClear()
        }

        lock.lock()
        activeProcess = process
        activePTYSession = session
        lock.unlock()

        session.inputTap = { [weak responder] bytes in
            responder?.observeInput(bytes)
        }
        // Ring buffer of the raw PTY output, so the tail survives even when
        // the UI feed has consumed it (recentOutput only covers pre-feed
        // buffering).
        let ptyTail = OSAllocatedUnfairLock<String>(initialState: "")
        session.startProcess(
            fileDescriptor: process.masterFD,
            onExit: {
                let tail = ptyTail.withLock { String($0.suffix(4096)) }
                if let message = Self.extractConnectionError(from: tail) {
                    Log.ssh.error("[PTY] Session failed: \(message)")
                    onError?(
                        SSHErrorMessageParser.explain(
                            tail,
                            host: self.config.host,
                            jumpHost: self.config.jumpHost?.host
                        ) ?? message
                    )
                } else if !tail.isEmpty {
                    Log.ssh.error("[PTY] Session exited. Raw tail:\n\(tail)")
                }
                onExit()
            },
            onOutput: { data in
                responder.observe(data)
                ptyTail.withLock {
                    $0.append(String(data: data, encoding: .utf8) ?? "")
                }
            }
        )
        return session
    }

    /// Execute one command with clean output.
    func executeCommand(_ command: String) async throws -> String {
        let arguments = sshArguments(
            pty: false,
            command: command,
            additionalOptions: []
        )
        let process = try OpenSSHProcessTransport.spawn(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            cols: 160,
            rows: 50,
            termType: "xterm-256color"
        )
        // The transport owns the PTY master fd; make sure it is released on
        // every exit path (success, error, cancellation). session.close()
        // does NOT close the fd (ownsFD == false).
        defer { process.close() }
        let session = PTYSession()
        let rawStream = session.makeRawOutputStream()
        let responder = makeAuthResponder(process: process, allowInteractivePrompt: true)
        session.startProcess(
            fileDescriptor: process.masterFD,
            onExit: {},
            onOutput: responder.observe
        )

        var output = ""
        for await chunk in rawStream {
            output.append(chunk)
        }
        let status = await process.waitForExit()
        session.close()

        guard status == 0 else {
            let detail = Self.cleanCommandOutput(output)
            throw SSHServiceError.connectionFailed(
                detail.isEmpty
                    ? "OpenSSH command exited with status \(status)."
                    : (SSHErrorMessageParser.explain(
                        detail,
                        host: config.host,
                        jumpHost: config.jumpHost?.host
                    ) ?? detail)
            )
        }
        return Self.cleanCommandOutput(output)
    }

    /// Execute commands against the system OpenSSH SFTP client.
    ///
    /// The SFTP process uses the same ControlPath and auth responder as the
    /// terminal process. This avoids a second native SSH connection and keeps
    /// password / keyboard-interactive authentication behavior consistent.
    ///
    /// Runs in INTERACTIVE mode (not `-b` batch): batch mode suppresses the
    /// progress meter entirely (verified empirically — `sftp -b` emits zero
    /// progress output even on a PTY), which made transfer progress bars
    /// never move. Interactive mode on the PTY emits `\r`-separated progress
    /// lines that OpenSSHSFTPClient's ProgressParser consumes. Commands are
    /// executed one at a time; each waits for the next `sftp>` prompt.
    func runSFTP(
        commands: [String],
        onOutput: (@Sendable (Data) -> Void)? = nil,
        registerProcess: (@Sendable (OpenSSHProcessTransport?) -> Void)? = nil
    ) async throws -> String {
        guard !commands.isEmpty else {
            throw SSHServiceError.connectionFailed("OpenSSH SFTP command list is empty.")
        }

        let process = try OpenSSHProcessTransport.spawn(
            executable: "/usr/bin/sftp",
            arguments: sftpArguments(),
            cols: 160,
            rows: 50,
            termType: "xterm-256color"
        )
        let session = PTYSession()
        let rawStream = session.makeRawOutputStream()
        let responder = makeAuthResponder(process: process, allowInteractivePrompt: true)
        registerProcess?(process)
        session.startProcess(
            fileDescriptor: process.masterFD,
            onExit: {},
            onOutput: { data in
                responder.observe(data)
                onOutput?(data)
            }
        )

        do {
            var output = ""
            var streamIterator = rawStream.makeAsyncIterator()

            for command in commands {
                try process.write(Data((command + "\n").utf8))

                // Read until the next `sftp>` prompt appears. Progress lines
                // (`\r`-rewritten) arrive before the prompt and are forwarded
                // via onOutput as they stream in.
                var chunkBuffer = ""
                while true {
                    guard let chunk = await streamIterator.next() else { break }
                    chunkBuffer.append(chunk)
                    output.append(chunk)
                    if Self.sftpPromptAppeared(in: chunkBuffer) { break }
                    if chunkBuffer.count > 128 * 1024 { break }
                }

                // Interactive mode keeps going after a failed command, so
                // detect failures per-command instead of via exit status.
                let cleaned = Self.cleanCommandOutput(chunkBuffer)
                if Self.sftpOutputContainsError(cleaned) {
                    throw SSHServiceError.connectionFailed(cleaned)
                }
            }

            // Leave cleanly and drain the rest.
            try? process.write(Data("quit\n".utf8))
            while let chunk = await streamIterator.next() {
                output.append(chunk)
            }

            let status = await process.waitForExit()
            session.close()
            process.close()
            registerProcess?(nil)

            guard status == 0 else {
                let detail = Self.cleanCommandOutput(output)
                throw SSHServiceError.connectionFailed(
                    detail.isEmpty
                        ? "OpenSSH SFTP exited with status \(status)."
                        : (SSHErrorMessageParser.explain(
                        detail,
                        host: config.host,
                        jumpHost: config.jumpHost?.host
                    ) ?? detail)
                )
            }
            return Self.cleanCommandOutput(output)
        } catch {
            registerProcess?(nil)
            session.close()
            process.close()
            throw error
        }
    }

    /// Whether the accumulated PTY output shows the sftp prompt at its end.
    private static func sftpPromptAppeared(in text: String) -> Bool {
        let stripped = text.replacingOccurrences(
            of: #"\u001B\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        return stripped.hasSuffix("sftp> ") || stripped.hasSuffix("sftp>")
    }

    /// Failure keywords for per-command error detection in interactive mode.
    private static func sftpOutputContainsError(_ text: String) -> Bool {
        let patterns: [String] = [
            "couldn't", "permission denied", "denied", "no such file",
            "not found", "failure", "lost connection", "connection closed",
            "is a directory", "can't open", "unable to",
        ]
        let lower = text.lowercased()
        return patterns.contains { lower.contains($0) }
    }

    func makeSFTPClient() -> OpenSSHSFTPClient {
        OpenSSHSFTPClient(backend: self)
    }

    /// Start OpenSSH `-N` forwarding process.
    func startPortForward(
        config forward: SSHPortForwardConfiguration,
        onExit: @escaping @Sendable () -> Void
    ) throws -> OpenSSHForwardHandle {
        let forwardOption: String
        switch forward.type {
        case .local:
            forwardOption = "-L\(forward.localHost):\(forward.localPort):\(forward.remoteHost):\(forward.remotePort)"
        case .remote:
            forwardOption = "-R\(forward.remoteHost):\(forward.remotePort):\(forward.localHost):\(forward.localPort)"
        case .dynamic:
            forwardOption = "-D\(forward.localHost):\(forward.localPort)"
        }

        let arguments = sshArguments(
            pty: false,
            command: nil,
            additionalOptions: [
                "-N",
                "-o", "ExitOnForwardFailure=yes",
                forwardOption,
            ]
        )
        let process = try OpenSSHProcessTransport.spawn(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            cols: 120,
            rows: 40,
            termType: "xterm-256color"
        )
        let session = PTYSession()
        let responder = makeAuthResponder(process: process, allowInteractivePrompt: true)
        session.startProcess(
            fileDescriptor: process.masterFD,
            onExit: onExit,
            onOutput: responder.observe
        )

        return OpenSSHForwardHandle(process: process, session: session)
    }

    func authCredentials() -> [OpenSSHPasswordCredential] {
        var credentials: [OpenSSHPasswordCredential] = []
        if let jumpHost = config.jumpHost,
           let jumpPassword = password(from: jumpHost.authMethod)
        {
            credentials.append(
                OpenSSHPasswordCredential(
                    username: jumpHost.username,
                    host: jumpHost.host,
                    password: jumpPassword
                )
            )
        }
        if let targetPassword = password(from: config.authMethod) {
            credentials.append(
                OpenSSHPasswordCredential(
                    username: config.username,
                    host: config.host,
                    password: targetPassword
                )
            )
        }
        return credentials
    }

    func writeToProcess(_ process: OpenSSHProcessTransport, _ data: Data) {
        try? process.write(data)
    }

    func close() {
        lock.lock()
        let process = activeProcess
        let session = activePTYSession
        activeProcess = nil
        activePTYSession = nil
        lock.unlock()

        session?.close()
        process?.close()
        closeControlMaster()

        for file in ([targetIdentityFile, targetCertificateFile, jumpIdentityFile, jumpCertificateFile] as [URL?]).compactMap(\.self) {
            try? FileManager.default.removeItem(at: file)
        }
        if let askpass = jumpAskpassPath {
            try? FileManager.default.removeItem(atPath: askpass)
        }
        targetIdentityFile = nil
        targetCertificateFile = nil
        jumpIdentityFile = nil
        jumpCertificateFile = nil
        jumpAskpassPath = nil
    }

    // MARK: - Command construction

    private func sshArguments(
        pty: Bool,
        command: String?,
        additionalOptions: [String]
    ) -> [String] {
        var args: [String] = []
        if pty {
            args += ["-tt"]
        } else {
            args += ["-o", "RequestTTY=no"]
        }

        args += commonOpenSSHArguments(additionalOptions: additionalOptions)
        args += ["-p", String(config.port), "\(config.username)@\(config.host)"]
        if let command {
            args.append(command)
        }
        return args
    }

    private func sftpArguments() -> [String] {
        var args = commonOpenSSHArguments(
            additionalOptions: [
                "-B", "131072",
                "-R", "128",
            ]
        )
        args += ["-P", String(config.port), "\(config.username)@\(config.host)"]
        return args
    }

    private func commonOpenSSHArguments(additionalOptions: [String]) -> [String] {
        var args: [String] = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=300",
            "-o", "ControlPath=\(controlPath)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "NumberOfPasswordPrompts=2",
            "-o", "ConnectTimeout=10",
        ]
        // Keep modern host-key algorithms first, but retain compatibility with
        // legacy JumpServer/OpenSSH servers that advertise only ssh-rsa.
        args += legacyRSACompatibilityArguments()
        args += authenticationArguments(for: config.authMethod)

        if let proxyCommand = jumpProxyCommand() {
            args += ["-o", "ProxyCommand=\(proxyCommand)"]
        }

        args += identityArguments()
        args += additionalOptions
        return args
    }

    private func identityArguments() -> [String] {
        var args: [String] = []
        if let targetIdentityFile {
            args += ["-i", targetIdentityFile.path]
        }
        if let targetCertificateFile {
            args += ["-o", "CertificateFile=\(targetCertificateFile.path)"]
        }
        return args
    }

    /// `+ssh-rsa` appends legacy RSA/SHA-1 instead of replacing modern
    /// algorithms. Modern servers still negotiate stronger algorithms first;
    /// old servers get a compatible fallback.
    private func legacyRSACompatibilityArguments() -> [String] {
        [
            "-o", "HostKeyAlgorithms=+ssh-rsa",
            "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
        ]
    }

    func makeAuthResponder(
        process: OpenSSHProcessTransport,
        allowInteractivePrompt: Bool
    ) -> OpenSSHAuthPromptResponder {
        var authUserHosts: [String] = []
        if let jumpHost = config.jumpHost {
            authUserHosts.append("\(jumpHost.username)@\(jumpHost.host)")
        }
        authUserHosts.append("\(config.username)@\(config.host)")

        return OpenSSHAuthPromptResponder(
            credentials: authCredentials(),
            authUserHosts: authUserHosts,
            allowInteractivePrompt: allowInteractivePrompt,
            allowUnscopedPassword: allowInteractivePrompt && config.jumpHost == nil,
            write: { [weak self, weak process] data in
                guard let self, let process else { return }
                self.writeToProcess(process, data)
            }
        )
    }

    private func password(from authMethod: SSHAuthMethod?) -> String? {
        guard case let .password(value) = authMethod else { return nil }
        return value
    }

    private func authenticationArguments(for authMethod: SSHAuthMethod?) -> [String] {
        switch authMethod {
        case .password:
            return [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=yes",
                "-o", "PubkeyAuthentication=no",
            ]
        case .privateKey, .certificate:
            return [
                "-o", "PreferredAuthentications=publickey,keyboard-interactive",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=yes",
            ]
        case .secureEnclaveKey:
            return [
                "-o", "PreferredAuthentications=publickey,keyboard-interactive",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=yes",
            ]
        case nil:
            return [
                "-o", "PreferredAuthentications=password,keyboard-interactive,publickey",
                "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=yes",
            ]
        }
    }

    private func prepareIdentityFiles() throws {
        switch config.authMethod {
        case let .privateKey(pemString):
            targetIdentityFile = try writeIdentityFile(pemString, suffix: ".key")
        case let .certificate(privateKeyPEM, certificatePEM):
            targetIdentityFile = try writeIdentityFile(privateKeyPEM, suffix: ".key")
            targetCertificateFile = try writeIdentityFile(certificatePEM, suffix: ".cert")
        case .password, .secureEnclaveKey:
            break
        }

        guard let jumpAuth = config.jumpHost?.authMethod else { return }
        switch jumpAuth {
        case let .privateKey(pemString):
            jumpIdentityFile = try writeIdentityFile(pemString, suffix: ".jump.key")
        case let .certificate(privateKeyPEM, certificatePEM):
            jumpIdentityFile = try writeIdentityFile(privateKeyPEM, suffix: ".jump.key")
            jumpCertificateFile = try writeIdentityFile(certificatePEM, suffix: ".jump.cert")
        case .password, .secureEnclaveKey:
            break
        }
    }

    private func writeIdentityFile(_ contents: String, suffix: String) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/bonk-ssh-\(UUID().uuidString)\(suffix)")
        let fileContents = Self.openSSHCompatiblePrivateKey(contents, suffix: suffix)
        try Data(fileContents.utf8).write(to: url, options: [.atomic])
        _ = chmod(url.path, mode_t(0o600))
        return url
    }

    /// Older Bonk versions stored Ed25519 seeds inside an
    /// `OPENSSH PRIVATE KEY` wrapper. That is not a valid OpenSSH key file.
    /// Convert that legacy representation only at the process boundary, so
    /// existing Keychain data and native iOS/Secure-Enclave paths remain
    /// unchanged.
    private static func openSSHCompatiblePrivateKey(
        _ contents: String,
        suffix: String
    ) -> String {
        guard suffix.hasSuffix(".key"),
              contents.contains("BEGIN OPENSSH PRIVATE KEY")
        else {
            return contents
        }

        let payload = contents
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        guard let seed = Data(
            base64Encoded: payload,
            options: [.ignoreUnknownCharacters]
        ), seed.count == 32,
        let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else {
            return contents
        }

        return encodeOpenSSHPrivateKey(
            seed: seed,
            publicKey: privateKey.publicKey.rawRepresentation
        )
    }

    private static func encodeOpenSSHPrivateKey(
        seed: Data,
        publicKey: Data
    ) -> String {
        var publicBlob = SSHBinaryWriter()
        publicBlob.writeString("ssh-ed25519")
        publicBlob.writeString(publicKey)

        var privateBlob = SSHBinaryWriter()
        let check = UInt32.random(in: UInt32.min ... UInt32.max)
        privateBlob.writeUInt32(check)
        privateBlob.writeUInt32(check)
        privateBlob.writeString("ssh-ed25519")
        privateBlob.writeString(publicKey)
        privateBlob.writeString(seed + publicKey)
        privateBlob.writeString("")

        let paddingLength = 8 - (privateBlob.data.count % 8)
        privateBlob.data.append(contentsOf: (1 ... paddingLength).map(UInt8.init))

        var key = SSHBinaryWriter()
        key.data.append(contentsOf: Array("openssh-key-v1\0".utf8))
        key.writeString("none")
        key.writeString("none")
        key.writeString(Data())
        key.writeUInt32(1)
        key.writeString(publicBlob.data)
        key.writeString(privateBlob.data)

        let base64 = key.data.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { offset in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(70, base64.distance(from: start, to: base64.endIndex)))
            return String(base64[start ..< end])
        }
        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(lines.joined(separator: "\n"))
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    private func jumpProxyCommand() -> String? {
        guard let jumpHost = config.jumpHost else { return nil }

        var args = [
            "/usr/bin/ssh",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "NumberOfPasswordPrompts=2",
            "-o", "ConnectTimeout=10",
            "-p", String(jumpHost.port),
        ]
        args += legacyRSACompatibilityArguments()
        args += authenticationArguments(for: jumpHost.authMethod)
        if let jumpIdentityFile {
            args += ["-i", jumpIdentityFile.path]
        }
        if let jumpCertificateFile {
            args += ["-o", "CertificateFile=\(jumpCertificateFile.path)"]
        }

        args += ["-W", "%h:%p", "\(jumpHost.username)@\(jumpHost.host)"]

        var command = args.map(Self.shellQuote).joined(separator: " ")

        // The ProxyCommand ssh has no TTY and its stdin/stdout are consumed
        // by the -W tunnel, so an interactive password prompt can never be
        // answered. Force SSH_ASKPASS so OpenSSH reads the jump password
        // from a throwaway script instead. The env prefix MUST be the
        // explicit `env VAR=...` form: OpenSSH's ProxyCommand shell (zsh on
        // macOS) mis-parses a bare `VAR=... cmd` prefix and tries to exec
        // the assignment as a program.
        if let jumpPassword = password(from: jumpHost.authMethod) {
            let askpassPath = writeAskPassScript(jumpPassword)
            jumpAskpassPath = askpassPath
            command = "env SSH_ASKPASS=\(Self.shellQuote(askpassPath)) SSH_ASKPASS_REQUIRE=force " + command
        }

        Log.ssh.info("[JUMP] ProxyCommand: \(command)")
        return command
    }

    /// Writes a 0700 script that echoes the jump password once. OpenSSH
    /// invokes it via SSH_ASKPASS; the file is removed when the connection
    /// closes.
    /// Passphrase-protected keys are not supported via ProxyCommand.
    private var jumpAskpassPath: String?

    private func writeAskPassScript(_ password: String) -> String {
        let path = "/tmp/bonk-ssh-askpass-\(UUID().uuidString)"
        let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\nprintf '%s\\n' '\(escaped)'\n"
        try? Data(script.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])
        _ = chmod(path, mode_t(0o700))
        return path
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func prepareKnownHostsPath() throws -> String {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Bonk", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appendingPathComponent("known_hosts").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
            _ = chmod(path, mode_t(0o600))
        }
        return path
    }

    private struct SSHBinaryWriter {
        var data = Data()

        mutating func writeUInt32(_ value: UInt32) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }

        mutating func writeString(_ value: String) {
            writeString(Data(value.utf8))
        }

        mutating func writeString(_ value: Data) {
            writeUInt32(UInt32(value.count))
            data.append(value)
        }
    }

    private func closeControlMaster() {
        guard FileManager.default.fileExists(atPath: controlPath) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-S", controlPath,
            "-O", "exit",
            "-p", String(config.port),
            "\(config.username)@\(config.host)",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: controlPath)
    }

    private static func cleanCommandOutput(_ output: String) -> String {
        output
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract a user-facing connection error from OpenSSH's PTY output.
    /// Returns nil when the output looks like a normal session end, so a
    /// successful disconnect never surfaces a spurious error.
    private static func extractConnectionError(from output: String) -> String? {
        let lower = output.lowercased()
        guard lower.contains("denied")
            || lower.contains("refused")
            || lower.contains("timed out")
            || lower.contains("prohibited")
            || lower.contains("no route")
            || lower.contains("unreachable")
            || lower.contains("closed")
            || lower.contains("host key")
            || lower.contains("negotiate")
            || lower.contains("authentication")
            || lower.contains("exchange_identification")
            || lower.contains("no such file")
            || lower.contains("not found")
            || lower.contains("could not resolve")
            || lower.contains("failed to allocate")
            || lower.contains("connection reset")
            || lower.contains("lost connection")
            || lower.contains("kex_exchange")
        else {
            return nil
        }

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let l = line.lowercased()
            let keywords = [
                "permission denied", "denied", "refused", "timed out",
                "administratively prohibited", "no route to host", "unreachable",
                "connection closed", "closed by remote", "host key verification failed",
                "unable to negotiate", "too many authentication failures",
                "ssh_exchange_identification", "no supported authentication methods",
                "connection reset", "lost connection", "could not resolve hostname",
                "failed to allocate pty", "kex_exchange_identification",
                "no such file", "not found",
            ]
            if keywords.contains(where: { l.contains($0) }) {
                return line
            }
        }
        return nil
    }
}

/// Lifetime handle for an OpenSSH forwarding process.
final class OpenSSHForwardHandle: @unchecked Sendable {
    private let process: OpenSSHProcessTransport
    private let session: PTYSession

    init(process: OpenSSHProcessTransport, session: PTYSession) {
        self.process = process
        self.session = session
    }

    func waitUntilExit() async {
        _ = await process.waitForExit()
    }

    func close() {
        session.close()
        process.close()
    }
}

#endif
