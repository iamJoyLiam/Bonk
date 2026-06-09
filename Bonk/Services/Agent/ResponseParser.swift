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
