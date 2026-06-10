import Foundation

/// Parses AI responses to extract thinking, command, and response text.
enum ResponseParser {
    struct Result {
        let thinking: String?
        let command: String?
        let response: String
    }

    static func parse(_ text: String) -> Result {
        // Try JSON first
        if let result = parseJSON(text) { return result }

        // Fallback: code block
        if let command = extractFromCodeBlock(text) {
            return Result(thinking: nil, command: command, response: text)
        }

        // Fallback: inline code
        if let command = extractFromInlineCode(text) {
            return Result(thinking: nil, command: command, response: text)
        }

        return Result(thinking: nil, command: nil, response: text)
    }

    struct PlanResult {
        let thinking: String?
        let response: String
        let steps: [(desc: String, cmd: String)]
    }

    /// Parse a plan response from the AI.
    static func parsePlan(_ text: String) -> PlanResult {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else
        {
            return PlanResult(thinking: nil, response: text, steps: [])
        }

        let thinking = json["thinking"] as? String
        let response = json["response"] as? String ?? text

        var steps: [(desc: String, cmd: String)] = []
        if let plan = json["plan"] as? [[String: Any]] {
            for item in plan {
                let desc = item["description"] as? String ?? ""
                let cmd = item["command"] as? String ?? ""
                if !cmd.isEmpty { steps.append((desc: desc, cmd: cmd)) }
            }
        }

        return PlanResult(thinking: thinking, response: response, steps: steps)
    }

    private static func parseJSON(_ text: String) -> Result? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else
        {
            return nil
        }

        let thinking = json["thinking"] as? String
        let command = json["command"] as? String
        let response = json["response"] as? String ?? text
        return Result(thinking: thinking, command: command, response: response)
    }

    private static func extractFromCodeBlock(_ text: String) -> String? {
        let pattern = #"```(?:bash|sh)?\n(.*?)\n```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else
        {
            return nil
        }
        let command = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.contains("\n") ? nil : command
    }

    private static func extractFromInlineCode(_ text: String) -> String? {
        let pattern = #"(?:Executing|Run|Command):\s*`([^`]+)`"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else
        {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
