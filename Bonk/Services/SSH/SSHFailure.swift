import Foundation

// MARK: - Typed failure — auth failed NEVER  Recovery

public enum AuthenticationFailure: Sendable, Equatable, Hashable, CustomStringConvertible {
    case permissionDenied(String)          // Permission denied, publickey/password
    case invalidCredentials(String)        // Authentication failed
    case allOptionsFailed(String)          // allAuthenticationOptionsFailed
    case tooManyFailures(String)
    case keyboardInteractiveRequired(String)
    case unknown(String)

    public var message: String {
        switch self {
        case .permissionDenied(let message), .invalidCredentials(let message), .allOptionsFailed(let message),
             .tooManyFailures(let message), .keyboardInteractiveRequired(let message), .unknown(let message):
            return message
        }
    }
    public var description: String { message }
}

public enum TransportFailure: Sendable, Equatable, Hashable, CustomStringConvertible {
    case connectionRefused(String)
    case timedOut(String)
    case unreachable(String)
    case reset(String)
    case dnsFailed(String)
    case exchangeFailed(String)
    case closed(String)
    case unknown(String)

    public var message: String {
        switch self {
        case .connectionRefused(let message), .timedOut(let message), .unreachable(let message), .reset(let message),
             .dnsFailed(let message), .exchangeFailed(let message), .closed(let message), .unknown(let message):
            return message
        }
    }
    public var description: String { message }
}

// /  typed error — OpenSSHBackend  String
public enum SSHFailure: Error, Sendable, Equatable, Hashable, CustomStringConvertible {
    case authentication(AuthenticationFailure)
    case transport(TransportFailure)
    case hostKey(String)
    case cancelled
    case unknown(String)

    public var isAuthentication: Bool {
        if case .authentication = self { return true }
        return false
    }
    public var isTransport: Bool {
        if case .transport = self { return true }
        return false
    }
    public var message: String {
        switch self {
        case .authentication(let authFailure): return authFailure.message
        case .transport(let transportFailure): return transportFailure.message
        case .hostKey(let message): return message
        case .cancelled: return "cancelled"
        case .unknown(let message): return message
        }
    }
    public var typeString: String {
        switch self {
        case .authentication: return "authentication"
        case .transport: return "transport"
        case .hostKey: return "hostKey"
        case .cancelled: return "cancelled"
        case .unknown: return "unknown"
        }
    }
    public var description: String { "\(typeString): \(message)" }
}

// MARK: - Unified OpenSSH classifier — stderr + PTY tail + exit status

enum SSHFailureClassifier {
    static func classify(tail: String, stderr: String, terminationStatus: Int32, wasUserClosed: Bool) -> SSHFailure? {
        // ： wasUserClosed / SIGHUP， tail  Permission denied auth failed， authentication，
        // reconnect teardown  close  isClosed=true ·auth failed cancelled， AuthRetrySheet  RECOVERY_GATE blocked
        let preCombined = (tail + "\n" + stderr).lowercased()
        let hasAuthSignal = preCombined.contains("permission denied") || preCombined.contains("authentication failed") || preCombined.contains("allauthenticationoptionsfailed") || preCombined.contains("too many authentication failures")
        if hasAuthSignal {
            // return cancelled， auth
        } else {
            if wasUserClosed { return .cancelled }
            if terminationStatus == 130 || terminationStatus == 143 || terminationStatus == 129 {
                return .cancelled
            }
        }
        let combined = (tail + "\n" + stderr)
        let lines = combined.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\r", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("debug") }

        if lines.isEmpty {
            if terminationStatus == 0 { return nil }
            if terminationStatus == 130 || terminationStatus == 143 { return .cancelled }
            return nil
        }

        for line in lines {
            let lower = line.lowercased()
            if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
                return .hostKey(line)
            }
            // authentication — Permission denied/publickey/password  .authentication
            if lower.contains("permission denied") || lower.contains("authentication failed") || lower.contains("authentication failure")
                || lower.contains("allauthenticationoptionsfailed") || lower.contains("all authentication options failed")
                || lower.contains("no supported authentication methods") || lower.contains("too many authentication failures")
                || lower.contains("no authentication methods") || lower.contains("publickey") && lower.contains("denied") {
                if lower.contains("allauthenticationoptionsfailed") || lower.contains("all authentication options failed") {
                    return .authentication(.allOptionsFailed(line))
                }
                if lower.contains("too many") { return .authentication(.tooManyFailures(line)) }
                return .authentication(.permissionDenied(line))
            }
            if lower.contains("administratively prohibited") || lower.contains("open failed") || lower.contains("connection closed by unknown port 65535")
                || lower.contains("channel 0:") {
                return .transport(.closed(line))
            }
            if lower.contains("connection refused") { return .transport(.connectionRefused(line)) }
            if lower.contains("connection timed out") || lower.contains("timed out") || lower.contains("timeout expired") {
                return .transport(.timedOut(line))
            }
            if lower.contains("no route to host") || lower.contains("network is unreachable") {
                return .transport(.unreachable(line))
            }
            if lower.contains("could not resolve hostname") || lower.contains("could not resolve") {
                return .transport(.dnsFailed(line))
            }
            if lower.contains("kex_exchange_identification") || lower.contains("ssh_exchange_identification") {
                return .transport(.exchangeFailed(line))
            }
            if lower.contains("connection reset") || lower.contains("connection closed by") {
                return .transport(.reset(line))
            }
            if lower.contains("unknown port") || lower.contains("connection closed") {
                return .transport(.closed(line))
            }
        }
        if let fallback = OpenSSHBackend.extractConnectionError(from: combined) {
            let lower = fallback.lowercased()
            if lower.contains("permission denied") || lower.contains("authentication") {
                return .authentication(.permissionDenied(fallback))
            }
            if lower.contains("host key") { return .hostKey(fallback) }
            if lower.contains("administratively prohibited") { return .transport(.closed(fallback)) }
            if lower.contains("refused") { return .transport(.connectionRefused(fallback)) }
            if lower.contains("timed out") { return .transport(.timedOut(fallback)) }
            if lower.contains("could not resolve") { return .transport(.dnsFailed(fallback)) }
            if lower.contains("connection") || lower.contains("reset") { return .transport(.reset(fallback)) }
            return .unknown(fallback)
        }
        return nil
    }

    // /  SSHProcessFailure  SSHFailure
    static func from(_ old: SSHProcessFailure) -> SSHFailure {
        switch old {
        case .authentication(let message):
            if message.lowercased().contains("allauthenticationoptionsfailed") || message.lowercased().contains("all authentication options failed") {
                return .authentication(.allOptionsFailed(message))
            }
            return .authentication(.permissionDenied(message))
        case .hostKey(let message): return .hostKey(message)
        case .network(let message):
            // transport
            let lower = message.lowercased()
            if lower.contains("refused") { return .transport(.connectionRefused(message)) }
            if lower.contains("timed out") { return .transport(.timedOut(message)) }
            if lower.contains("no route") || lower.contains("unreachable") { return .transport(.unreachable(message)) }
            if lower.contains("could not resolve") { return .transport(.dnsFailed(message)) }
            if lower.contains("reset") || lower.contains("closed by") { return .transport(.reset(message)) }
            return .transport(.unknown(message))
        case .forwarding(let message): return .transport(.closed(message))
        case .cancelled: return .cancelled
        case .unknown(let message): return .unknown(message)
        }
    }
}
