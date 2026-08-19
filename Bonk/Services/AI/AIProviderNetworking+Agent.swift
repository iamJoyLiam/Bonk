import Foundation

extension AIProviderNetworking {
    /// Parse a chat-completions payload into text + tool calls.
    /// Pure function so it is unit-testable.
    static func parseAgentTurn(from data: Data) throws -> AgentChatTurn {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else {
            throw AIError.invalidResponse
        }

        let content = message["content"] as? String
        var calls: [AgentToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                guard let id = raw["id"] as? String,
                      let function = raw["function"] as? [String: Any],
                      let name = function["name"] as? String
                else { continue }
                let argsString = function["arguments"] as? String ?? ""
                calls.append(LLMToolCall(id: id, name: name, argumentsJSON: argsString))
            }
        }
        return LLMResponse(text: content ?? "", toolCalls: calls)
    }
}
