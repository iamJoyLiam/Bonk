import Foundation

/// Parses AI plan responses.
enum ResponseParser {
    struct PlanResult {
        let thinking: String?
        let response: String
        let steps: [(desc: String, cmd: String)]
    }

    /// Parse a plan response from the AI.
    static func parsePlan(_ text: String) -> PlanResult {
        guard let json = extractJSON(from: text) else {
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

    /// Pull a JSON object out of a model reply. Tolerates ```json fences,
    /// prose around the JSON, and partial prefixes — models rarely return a
    /// bare, valid JSON document.
    private static func extractJSON(from text: String) -> [String: Any]? {
        // Direct parse first (fast path).
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return json
        }

        // Strip markdown code fences.
        var candidate = text
        if let fenceRange = candidate.range(of: "```"),
           let closing = candidate.range(
               of: "```",
               options: .backwards,
               range: fenceRange.upperBound..<candidate.endIndex
           ) {
            candidate = String(candidate[fenceRange.upperBound..<closing.lowerBound])
        }
        if let data = candidate.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return json
        }

        // Last resort: scan for the outermost balanced braces.
        guard let start = candidate.firstIndex(of: "{"),
              let end = candidate.lastIndex(of: "}"),
              start < end
        else { return nil }

        let slice = candidate[start...end]
        guard let data = String(slice).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
