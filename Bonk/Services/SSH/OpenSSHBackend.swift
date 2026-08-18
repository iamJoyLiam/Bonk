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

/// OpenSSH-backed network transport.
///
/// One backend owns one target configuration and one short-lived control
/// socket. Terminal, exec, and forwarding commands share that socket, so MFA
/// is normally completed once per target session. SFTP remains on native
/// Citadel path for compatibility.
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

    init(config: SSHConnectionConfig) throws {
        self.config = config
        controlPath = "/tmp/bonk-ssh-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
        knownHostsPath = try Self.prepareKnownHostsPath()
        try prepareIdentityFiles()
    }

    /// Open an interactive terminal.
    func openPTY(
        cols: Int,
        rows: Int,
        termType: String,
        onExit: @escaping @Sendable () -> Void
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

        lock.lock()
        activeProcess = process
        activePTYSession = session
        lock.unlock()

        session.startProcess(
            fileDescriptor: process.masterFD,
            onExit: onExit,
            onOutput: responder.observe
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
            throw SSHServiceError.connectionFailed(
                "OpenSSH command exited with status \(status)."
            )
        }
        return Self.cleanCommandOutput(output)
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

        for file in [targetIdentityFile, targetCertificateFile, jumpIdentityFile, jumpCertificateFile].compactMap(\.self) {
            try? FileManager.default.removeItem(at: file)
        }
        targetIdentityFile = nil
        targetCertificateFile = nil
        jumpIdentityFile = nil
        jumpCertificateFile = nil
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

        args += [
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

        args += ["-p", String(config.port), "\(config.username)@\(config.host)"]
        if let command {
            args.append(command)
        }
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

    private func makeAuthResponder(
        process: OpenSSHProcessTransport,
        allowInteractivePrompt: Bool
    ) -> OpenSSHAuthPromptResponder {
        OpenSSHAuthPromptResponder(
            credentials: authCredentials(),
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
        return args.map(Self.shellQuote).joined(separator: " ")
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
