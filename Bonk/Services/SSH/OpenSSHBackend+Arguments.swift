#if os(macOS)
import Foundation
import os.log

// MARK: - SSH argument construction (extracted)

extension OpenSSHBackend {
    func sshArguments(
        pty: Bool,
        command: String?,
        additionalOptions: [String],
        attemptID: String
    ) -> [String] {
        var args: [String] = []
        args += pty ? ["-tt"] : ["-o", "RequestTTY=no"]
        args += commonOpenSSHArguments(additionalOptions: additionalOptions, attemptID: attemptID)
        args += ["-p", String(config.port), "\(config.username)@\(config.host)"]
        if let command { args.append(command) }
        return args
    }

    func sftpArguments(attemptID: String) -> [String] {
        var args = commonOpenSSHArguments(
            additionalOptions: ["-B", "131072", "-R", "128"],
            attemptID: attemptID
        )
        args += ["-P", String(config.port), "\(config.username)@\(config.host)"]
        return args
    }

    func commonOpenSSHArguments(additionalOptions: [String], attemptID: String) -> [String] {
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
        args += legacyRSACompatibilityArguments()
        if let req = config.algorithmRequirements, !req.isEmpty {
            args += algorithmRequirementsArguments(req)
        }
        args += authenticationArguments(for: config.authMethod)
        if let proxyCommand = jumpProxyCommand(attemptID: attemptID) {
            args += ["-o", "ProxyCommand=\(proxyCommand)"]
        }
        args += identityArguments()
        args += additionalOptions
        return args
    }

    func identityArguments() -> [String] {
        var args: [String] = []
        if let targetIdentityFile { args += ["-i", targetIdentityFile.path] }
        if let targetCertificateFile { args += ["-o", "CertificateFile=\(targetCertificateFile.path)"] }
        return args
    }

    func legacyRSACompatibilityArguments() -> [String] {
        ["-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa"]
    }

    func algorithmRequirementsArguments(_ req: SSHAlgorithmRequirements) -> [String] {
        var args: [String] = []
        if !req.kex.isEmpty { args += ["-o", "KexAlgorithms=+\(req.kex.joined(separator: ","))"] }
        if !req.hostKey.isEmpty { args += ["-o", "HostKeyAlgorithms=+\(req.hostKey.joined(separator: ","))"] }
        if !req.cipher.isEmpty { args += ["-o", "Ciphers=+\(req.cipher.joined(separator: ","))"] }
        if !req.mac.isEmpty { args += ["-o", "MACs=+\(req.mac.joined(separator: ","))"] }
        return args
    }

    func authenticationArguments(for authMethod: SSHAuthMethod?) -> [String] {
        switch authMethod {
        case .password:
            return ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PasswordAuthentication=yes", "-o", "KbdInteractiveAuthentication=yes", "-o", "PubkeyAuthentication=no"]
        case .privateKey, .certificate:
            return ["-o", "PreferredAuthentications=publickey,keyboard-interactive", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=yes"]
        case .secureEnclaveKey:
            return ["-o", "PreferredAuthentications=publickey,keyboard-interactive", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=yes"]
        case nil:
            return ["-o", "PreferredAuthentications=password,keyboard-interactive,publickey", "-o", "PasswordAuthentication=yes", "-o", "KbdInteractiveAuthentication=yes"]
        }
    }

    func jumpProxyCommand(attemptID: String) -> String? {
        guard let jumpHost = config.jumpHost else { return nil }
        var args = [
            "/usr/bin/ssh", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "NumberOfPasswordPrompts=2",
            "-o", "ConnectTimeout=10", "-p", String(jumpHost.port),
        ]
        args += legacyRSACompatibilityArguments()
        args += authenticationArguments(for: jumpHost.authMethod)
        if let jumpIdentityFile { args += ["-i", jumpIdentityFile.path] }
        if let jumpCertificateFile { args += ["-o", "CertificateFile=\(jumpCertificateFile.path)"] }
        args += ["-W", "%h:%p", "\(jumpHost.username)@\(jumpHost.host)"]
        var command = args.map(Self.shellQuote).joined(separator: " ")
        if let jumpPassword = password(from: jumpHost.authMethod) {
            let askpassPath = writeAskPassScript(jumpPassword, attemptID: attemptID, host: jumpHost.host, username: jumpHost.username)
            jumpAskpassPath = askpassPath
            command = "env SSH_ASKPASS=\(Self.shellQuote(askpassPath)) SSH_ASKPASS_REQUIRE=force " + command
            Log.ssh.info("[ASKPASS] attempt=\(attemptID) script=\(askpassPath) host=\(jumpHost.host) username=\(jumpHost.username) passwordLength=\(jumpPassword.count) fp=\(Self.passwordFingerprint(jumpPassword))")
        }
        Log.ssh.info("[JUMP] ProxyCommand: \(command)")
        return command
    }
}
#endif
