import Foundation

/// Unified failure classification for OpenSSH process termination.
/// Covers PTY tail, stderr, and terminationStatus.
enum SSHProcessFailure: Equatable {
    case authentication(String) // Permission denied, allAuthenticationOptionsFailed, etc.
    case hostKey(String)        // Host key verification failed
    case network(String)        // Connection refused, timed out, no route, reset, etc.
    case forwarding(String)     // administratively prohibited, open failed, UNKNOWN port 65535
    case cancelled              // User cancelled / SIGHUP after close()
    case unknown(String)        // Fallback

    var isAuthentication: Bool {
        if case .authentication = self { return true }
        return false
    }
    var message: String {
        switch self {
        case .authentication(let m), .hostKey(let m), .network(let m), .forwarding(let m), .unknown(let m): return m
        case .cancelled: return "cancelled"
        }
    }
}

enum SSHProcessFailureClassifier {
    /// Classify from PTY tail + stderr + terminationStatus.
    /// Priority: cancelled > hostKey > authentication > forwarding > network > unknown
    static func classify(tail: String, stderr: String, terminationStatus: Int32, wasUserClosed: Bool) -> SSHProcessFailure? {
        if wasUserClosed { return .cancelled }
        // Combine tail+stderr, strip ANSI, split lines
        let combined = (tail + "\n" + stderr)
        let lines = combined.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\r", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("debug") }
        guard !lines.isEmpty else {
            // No output but non-zero exit -> check status
            if terminationStatus == 0 { return nil }
            if terminationStatus == 130 || terminationStatus == 143 { return .cancelled } // SIGINT/SIGTERM
            return nil
        }
        // Check each line in priority order
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
                return .hostKey(line)
            }
            if lower.contains("permission denied") || lower.contains("authentication failed") || lower.contains("authentication failure")
                || lower.contains("allauthenticationoptionsfailed") || lower.contains("all authentication options failed")
                || lower.contains("no supported authentication methods") || lower.contains("too many authentication failures")
                || lower.contains("no authentication methods") {
                return .authentication(line)
            }
            if lower.contains("administratively prohibited") || lower.contains("open failed") || lower.contains("connection closed by unknown port 65535")
                || lower.contains("channel 0:") {
                return .forwarding(line)
            }
            if lower.contains("connection refused") || lower.contains("connection timed out") || lower.contains("no route to host")
                || lower.contains("network is unreachable") || lower.contains("could not resolve hostname")
                || lower.contains("kex_exchange_identification") || lower.contains("ssh_exchange_identification")
                || lower.contains("connection reset") || lower.contains("connection closed by") || lower.contains("unknown port")
                || lower.contains("timed out") || lower.contains("timeout expired") {
                return .network(line)
            }
        }
        // Fallback: use extractConnectionError heuristic
        if let fallback = OpenSSHBackend.extractConnectionError(from: combined) {
            let lower = fallback.lowercased()
            if lower.contains("permission denied") || lower.contains("authentication") { return .authentication(fallback) }
            if lower.contains("host key") { return .hostKey(fallback) }
            if lower.contains("administratively prohibited") { return .forwarding(fallback) }
            if lower.contains("connection") || lower.contains("refused") || lower.contains("timed out") { return .network(fallback) }
            return .unknown(fallback)
        }
        return nil
    }
}
