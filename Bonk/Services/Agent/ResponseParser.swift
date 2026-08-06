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
}
