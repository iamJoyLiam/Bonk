//  LayaDecisionEngine.swift
//  Bonk
//
//  DecisionEngine adapter for a local Laya service. Laya ships as a Python
//  library with no HTTP server, so Bonk defines a small bridge contract and
//  ships a reference implementation (bonk-laya-bridge.py, same directory):
//
//    POST {endpoint}/v1/decide  {state, questions, checkpoint?} -> {answers}
//    GET  {endpoint}/v1/health  -> 200 when a checkpoint is loaded
//
//  Question/answer shapes mirror TypeSafe SystemOne, so the mapping is
//  shared with JevDecisionEngine. Empty checkpoint = bridge Router auto-picks.

import Foundation

/// Laya adapter (local sidecar over HTTP). Same protocol, no caller changes.
struct LayaDecisionEngine: DecisionEngine, Sendable {
    let engineName = "laya"
    let choiceConfidenceSource = "laya_top_probability"
    let endpoint: URL
    /// Laya checkpoint name (e.g. "english", "multilingual", "typed-decisions").
    /// Empty means the bridge Router selects automatically.
    let checkpoint: String
    let transport: any SystemOneTransport
    let timeoutSeconds: Double

    init(
        endpoint: URL,
        checkpoint: String = "",
        transport: any SystemOneTransport = URLSession.shared,
        timeoutSeconds: Double = 2
    ) {
        self.endpoint = endpoint
        self.checkpoint = checkpoint
        self.transport = transport
        self.timeoutSeconds = timeoutSeconds
    }

    private var client: SystemOneClient {
        SystemOneClient(
            endpoint: endpoint, path: "v1/decide",
            modelField: "checkpoint", modelValue: checkpoint,
            timeoutSeconds: timeoutSeconds, transport: transport
        )
    }

    // MARK: - DecisionEngine (Choice gates on top probability; see below)

    func choose(options: [DecisionOption], context: DecisionContext) async throws -> ChoiceDecision {
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
        let answer = answers["pick"]
        let (selectedID, _) = SystemOneMapping.interpretChoice(
            answer, validIDs: Set(options.map(\.id))
        )
        // Laya-specific: gate on the winner's top-1 probability, NOT the
        // reported confidence. Base checkpoints ship uncalibrated
        // (temperature unfitted): correct picks measured at 0.17–0.54
        // confidence against 0.63–0.86 top probability, so thresholding on
        // confidence would suppress right answers. Revisit (use confidence)
        // once per-domain temperatures are fitted from DecisionTrace data.
        let confidence = answer?.topProbability ?? answer?.confidence ?? 0
        return ChoiceDecision(selectedID: selectedID, confidence: confidence, rationale: .modelJudgment(nil))
    }

    func gate(question: String, context: DecisionContext) async throws -> GateDecision {
        let state = try requireState(context)
        let answers = try await client.ask(
            state: state,
            questions: ["proceed": SystemOneQuestion(type: "noul", instructions: question, criteria: nil)]
        )
        guard let prob = answers["proceed"]?.noul else {
            throw DecisionEngineError.badResponse("missing noul")
        }
        return GateDecision(shouldProceed: prob >= 0.5, confidence: abs(prob * 2 - 1))
    }

    func score(option _: DecisionOption, context: DecisionContext) async throws -> ScoreDecision {
        let state = try requireState(context)
        guard let levelsRaw = context.facts["levels"], !levelsRaw.isEmpty else {
            throw DecisionEngineError.missingRubric
        }
        let levels = levelsRaw.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !levels.isEmpty else { throw DecisionEngineError.missingRubric }
        let instructions = context.facts["question"] ?? "Rate the candidate against the ordered levels."
        let answers = try await client.ask(
            state: state,
            questions: [
                "grade": SystemOneQuestion(
                    type: "score",
                    instructions: instructions,
                    criteria: .levels(levels)
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
        try await client.checkHealth(healthPath: "v1/health")
    }

    // MARK: - Private

    private func requireState(_ context: DecisionContext) throws -> String {
        guard let state = context.facts["state"], !state.isEmpty else {
            throw DecisionEngineError.missingState
        }
        return state
    }
}
