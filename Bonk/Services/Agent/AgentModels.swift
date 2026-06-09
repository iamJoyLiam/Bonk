import Foundation

/// A message in an Agent conversation.
struct AgentMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    let command: String?
    let thinking: String?
    let timestamp = Date()

    enum Role {
        case user
        case assistant
        case system
        case commandOutput
    }

    init(role: Role, content: String, command: String? = nil, thinking: String? = nil) {
        self.role = role
        self.content = content
        self.command = command
        self.thinking = thinking
    }

    /// Convert to AI API message format.
    func toAIMessages() -> [[String: String]] {
        switch role {
        case .user:
            return [["role": "user", "content": content]]
        case .assistant:
            var text = content
            if let thinking { text = "💭 \(thinking)\n\n\(text)" }
            if let command { text += "\n\nExecuting: `\(command)`" }
            return [["role": "assistant", "content": text]]
        case .commandOutput:
            return [["role": "user", "content": "Command output:\n```\n\(content)\n```"]]
        case .system:
            return [["role": "user", "content": "[System: \(content)]"]]
        }
    }
}

/// A command pending user confirmation.
struct PendingCommand: Identifiable {
    let id = UUID()
    let command: String
    let reason: String
    let riskLevel: RiskLevel
    let continuation: (Bool) -> Void

    enum RiskLevel {
        case moderate
        case dangerous

        var icon: String {
            switch self {
            case .moderate: "exclamationmark.triangle"
            case .dangerous: "exclamationmark.octagon"
            }
        }

        var color: String {
            switch self {
            case .moderate: "orange"
            case .dangerous: "red"
            }
        }
    }
}

/// Timeout error for Agent operations.
struct TimeoutError: Error {}
