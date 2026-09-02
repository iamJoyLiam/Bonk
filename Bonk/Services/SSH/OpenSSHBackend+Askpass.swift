#if os(macOS)
import Crypto
import Foundation
import os.log

// MARK: - Askpass & shell quoting (extracted from OpenSSHBackend.swift)

extension OpenSSHBackend {
    /// SHA-256 fingerprint of a password for cross-checking WITHOUT logging the secret.
    static func passwordFingerprint(_ password: String) -> String {
        let digest = SHA256.hash(data: Data(password.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Writes a 0700 script that echoes the password once via SSH_ASKPASS.
    // / ： ' $ ` \ ! ， 0600  secret ， cat ， stdout
    func writeAskPassScript(
        _ password: String,
        attemptID: String,
        host: String,
        username: String
    ) -> String {
        let path = "/tmp/bonk-ssh-askpass-\(attemptID)"
        let secretPath = "/tmp/bonk-ssh-askpass-\(attemptID).secret"
        // 0600 secret ， shell
        if let data = password.data(using: .utf8) {
            try? data.write(to: URL(fileURLWithPath: secretPath), options: [.atomic])
            _ = chmod(secretPath, mode_t(0o600))
        }
        let script = """
        #!/bin/sh
        attempt=$(basename "$0" | sed 's/^bonk-ssh-askpass-//')
        /usr/bin/logger -t bonk.askpass "[ASKPASS] attempt=$attempt invoked host=\(Self.shellQuote(host)) username=\(Self.shellQuote(username)) passwordLength=\(password.count)"
        cat "\(secretPath)"
        printf '\\n'
        """
        try? Data(script.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])
        _ = chmod(path, mode_t(0o700))
        return path
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
#endif
