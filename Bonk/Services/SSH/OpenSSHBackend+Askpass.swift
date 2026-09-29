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
        // Both files are created 0600 at creation time; see SecureTempFile
        // for why write-then-chmod is not acceptable.
        let secretFile = try? SecureTempFile.create(
            name: "bonk-ssh-askpass-\(attemptID).secret",
            contents: Data(password.utf8)
        )
        guard let secretFile else { return Self.unusableAskpassPath(attemptID) }
        let script = """
        #!/bin/sh
        attempt=$(basename "$0" | sed 's/^bonk-ssh-askpass-//')
        /usr/bin/logger -t bonk.askpass "[ASKPASS] attempt=$attempt invoked host=\(Self.shellQuote(host)) username=\(Self.shellQuote(username)) passwordLength=\(password.count)"
        cat "\(Self.shellQuote(secretFile.path))"
        printf '\\n'
        """
        // 0700: the script is executable, and it is the only thing that reads
        // the secret, so it must not be writable by anyone else.
        let scriptFile = try? SecureTempFile.create(
            name: "bonk-ssh-askpass-\(attemptID)",
            contents: Data(script.utf8)
        )
        guard let scriptFile else {
            // Never leave the secret behind when the script cannot be created.
            secretFile.remove()
            return Self.unusableAskpassPath(attemptID)
        }
        // The script must be executable. Widening 0600 → 0700 only adds owner
        // execute; group/other stay absent, so no new exposure.
        _ = chmod(scriptFile.path, mode_t(0o700))
        return scriptFile.path
    }

    /// A path that cannot exist, returned when the askpass pair could not be
    /// created. The connection then fails instead of running with a
    /// half-initialised credential pair.
    private static func unusableAskpassPath(_ attemptID: String) -> String {
        "/nonexistent/bonk-askpass-\(attemptID)"
    }

    /// Remove an askpass script together with its secret file.
    static func removeAskpassPair(at scriptPath: String) {
        try? FileManager.default.removeItem(atPath: scriptPath)
        try? FileManager.default.removeItem(atPath: scriptPath + ".secret")
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
#endif
