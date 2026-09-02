import Foundation

// MARK: - Typed failure — 认证失败必须 NEVER 进入 Recovery

public enum AuthenticationFailure: Sendable, Equatable, Hashable, CustomStringConvertible {
    case permissionDenied(String)          // Permission denied, publickey/password
    case invalidCredentials(String)        // Authentication failed
    case allOptionsFailed(String)          // allAuthenticationOptionsFailed
    case tooManyFailures(String)
    case keyboardInteractiveRequired(String)
    case unknown(String)

    public var message: String {
        switch self {
        case .permissionDenied(let m), .invalidCredentials(let m), .allOptionsFailed(let m),
             .tooManyFailures(let m), .keyboardInteractiveRequired(let m), .unknown(let m):
            return m
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
        case .connectionRefused(let m), .timedOut(let m), .unreachable(let m), .reset(let m),
             .dnsFailed(let m), .exchangeFailed(let m), .closed(let m), .unknown(let m):
            return m
        }
    }
    public var description: String { message }
}

/// 顶层 typed error — OpenSSHBackend 不再只返回 String
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
        case .authentication(let a): return a.message
        case .transport(let t): return t.message
        case .hostKey(let m): return m
        case .cancelled: return "cancelled"
        case .unknown(let m): return m
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
        // 关键修复：即使 wasUserClosed / SIGHUP，若 tail 明确含 Permission denied 等认证失败，必须优先判为 authentication，
        // 否则 reconnect teardown 时 close() 置 isClosed=true 会把真·认证失败误判为 cancelled，导致不弹 AuthRetrySheet 而直接进 RECOVERY_GATE blocked
        let preCombined = (tail + "\n" + stderr).lowercased()
        let hasAuthSignal = preCombined.contains("permission denied") || preCombined.contains("authentication failed") || preCombined.contains("allauthenticationoptionsfailed") || preCombined.contains("too many authentication failures")
        if hasAuthSignal {
            // 不提前 return cancelled，让下文 auth 分支优先命中
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
            // authentication — Permission denied/publickey/password 必须映射 .authentication
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

    /// 将老的 SSHProcessFailure 映射到新 SSHFailure（兼容）
    static func from(_ old: SSHProcessFailure) -> SSHFailure {
        switch old {
        case .authentication(let m):
            if m.lowercased().contains("allauthenticationoptionsfailed") || m.lowercased().contains("all authentication options failed") {
                return .authentication(.allOptionsFailed(m))
            }
            return .authentication(.permissionDenied(m))
        case .hostKey(let m): return .hostKey(m)
        case .network(let m):
            // 粗略映射到 transport
            let lower = m.lowercased()
            if lower.contains("refused") { return .transport(.connectionRefused(m)) }
            if lower.contains("timed out") { return .transport(.timedOut(m)) }
            if lower.contains("no route") || lower.contains("unreachable") { return .transport(.unreachable(m)) }
            if lower.contains("could not resolve") { return .transport(.dnsFailed(m)) }
            if lower.contains("reset") || lower.contains("closed by") { return .transport(.reset(m)) }
            return .transport(.unknown(m))
        case .forwarding(let m): return .transport(.closed(m))
        case .cancelled: return .cancelled
        case .unknown(let m): return .unknown(m)
        }
    }
}
