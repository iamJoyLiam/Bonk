//  JevDecisionEngine.swift
//  Bonk
//
//  DecisionEngine adapter for TypeSafe Jev (cloud API).
//  POST {endpoint}/v1/systemone with Bearer key; typed questions in,
//  typed answers out. Key lives in the Keychain (see DecisionEngineKeychain)
//  and is passed in — this type never reads storage itself.

import Foundation

/// Jev adapter. Same DecisionEngine protocol as the deterministic engine,
/// so callers never branch on engine kind.
struct JevDecisionEngine: DecisionEngine, Sendable {
    let engineName = "jev"
    let choiceConfidenceSource = "jev_concentration"
    let endpoint: URL
    let model: String
    let apiKey: String
    let transport: any SystemOneTransport
    let timeoutSeconds: Double

    init(
        endpoint: URL,
        model: String = "jev-latest",
        apiKey: String,
        transport: any SystemOneTransport = URLSession.shared,
        timeoutSeconds: Double = 8
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
        self.timeoutSeconds = timeoutSeconds
    }

    private var client: SystemOneClient {
        SystemOneClient(
            endpoint: endpoint, path: "v1/systemone",
            modelField: "model", modelValue: model,
            bearerKey: apiKey, timeoutSeconds: timeoutSeconds, transport: transport
        )
    }

    // MARK: - DecisionEngine

    func choose(options: [DecisionOption], context: DecisionContext) async throws -> ChoiceDecision {
        guard !apiKey.isEmpty else { throw DecisionEngineError.missingAPIKey }
        let state = try requireState(context)
        let instructions = context.facts["question"] ?? "Select the option that best matches the user's intent."
        let allowNone = context.facts["allow_none"] == "true"
        let answers = try await client.ask(
            state: state,
            questions: [
                "pick": SystemOneMapping.choiceQuestion(
                    options: options,
                    instructions: instructions,
                    allowNone: allowNone
                ),
            ]
        )
        let (selectedID, confidence) = SystemOneMapping.interpretChoice(
            answers["pick"], validIDs: Set(options.map(\.id))
        )
        return ChoiceDecision(selectedID: selectedID, confidence: confidence, rationale: .modelJudgment(nil))
    }

    func gate(question: String, context: DecisionContext) async throws -> GateDecision {
        guard !apiKey.isEmpty else { throw DecisionEngineError.missingAPIKey }
        let state = try requireState(context)
        let answers = try await client.ask(
            state: state,
            questions: ["proceed": SystemOneQuestion(type: "noul", instructions: question, criteria: nil)]
        )
        guard let prob = answers["proceed"]?.noul else {
            throw DecisionEngineError.badResponse("missing noul")
        }
        // Confidence = distance from maximum uncertainty (0.5).
        return GateDecision(shouldProceed: prob >= 0.5, confidence: abs(prob * 2 - 1))
    }

    func score(option _: DecisionOption, context: DecisionContext) async throws -> ScoreDecision {
        guard !apiKey.isEmpty else { throw DecisionEngineError.missingAPIKey }
        let state = try requireState(context)
        guard let levelsRaw = context.facts["levels"], !levelsRaw.isEmpty else {
            throw DecisionEngineError.missingRubric
        }
        let levels = levelsRaw.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !levels.isEmpty else { throw DecisionEngineError.missingRubric }
        // Jev accepts at most 10 score levels (422 otherwise).
        let cappedLevels = Array(levels.prefix(10))
        let instructions = context.facts["question"] ?? "Rate the candidate against the ordered levels."
        let answers = try await client.ask(
            state: state,
            questions: [
                "grade": SystemOneQuestion(
                    type: "score",
                    instructions: instructions,
                    criteria: .levels(cappedLevels)
                ),
            ]
        )
        guard let answer = answers["grade"], let value = answer.score else {
            throw DecisionEngineError.badResponse("missing score")
        }
        return ScoreDecision(score: value, confidence: answer.confidence ?? 0)
    }

    // MARK: - Health

    /// Liveness probe used by Settings → Test. Throws when unreachable.
    func checkHealth() async throws {
        guard !apiKey.isEmpty else { throw DecisionEngineError.missingAPIKey }
        try await client.checkHealth(healthPath: "v1/models")
    }

    // MARK: - Private

    private func requireState(_ context: DecisionContext) throws -> String {
        guard let state = context.facts["state"], !state.isEmpty else {
            throw DecisionEngineError.missingState
        }
        return state
    }
}
