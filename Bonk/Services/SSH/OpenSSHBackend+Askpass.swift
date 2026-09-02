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
    /// 修复：密码不再直接嵌入脚本单引号（避免 ' $ ` \ ! 换行等转义遗漏），改为写入 0600 临时 secret 文件，脚本 cat 该文件，确保 stdout 仅为密码本身
    func writeAskPassScript(
        _ password: String,
        attemptID: String,
        host: String,
        username: String
    ) -> String {
        let path = "/tmp/bonk-ssh-askpass-\(attemptID)"
        let secretPath = "/tmp/bonk-ssh-askpass-\(attemptID).secret"
        // 0600 secret 文件，避免 shell 转义问题
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
