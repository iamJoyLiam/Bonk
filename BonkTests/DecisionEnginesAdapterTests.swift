//
//  DecisionEnginesAdapterTests.swift
//  BonkTests
//
//  Phase-2 adapter tests: config persistence, factory selection, Jev/Laya
//  wire mapping over an instance-scoped fake transport (no network, no
//  global stub state — safe under Swift Testing parallelism), threshold
//  gating in decideBest, and deterministic fallback paths.
//

@testable import Bonk
import Foundation
import Testing

// MARK: - Fake transport (instance-scoped, parallel-safe)

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock(); _requests.append(request); lock.unlock()
    }

    var last: URLRequest? {
        lock.lock(); defer { lock.unlock() }; return _requests.last
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return _requests.count
    }
}

struct FakeTransport: SystemOneTransport, Sendable {
    let status: Int
    let body: Data
    let log: RequestLog

    init(status: Int = 200, json: String = "{}", log: RequestLog = RequestLog()) {
        self.status = status
        self.body = Data(json.utf8)
        self.log = log
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        log.append(request)
        guard let url = request.url else { throw DecisionEngineError.badResponse("no url") }
        let response = HTTPURLResponse(
            url: url, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}

func testDefaults(suite: String = "test-decision-\(UUID().uuidString)") -> UserDefaults {
    UserDefaults(suiteName: suite)!
}

// MARK: - Low-confidence spy for threshold tests

actor FlakyDecisionEngine: DecisionEngine {
    let engineName = "flaky"
    let choiceConfidenceSource = "flaky"
    let selection: String?
    let confidence: Double

    init(selection: String?, confidence: Double) {
        self.selection = selection
        self.confidence = confidence
    }

    func choose(options: [DecisionOption], context _: DecisionContext) async throws -> ChoiceDecision {
        ChoiceDecision(
            selectedID: selection ?? options.first?.id,
            confidence: confidence,
            rationale: .modelJudgment("flaky")
        )
    }

    func gate(question _: String, context _: DecisionContext) async throws -> GateDecision {
        GateDecision(shouldProceed: true, confidence: confidence)
    }

    func score(option: DecisionOption, context _: DecisionContext) async throws -> ScoreDecision {
        ScoreDecision(score: option.localScore, confidence: confidence)
    }
}

@Suite("Decision Engine Adapters")
@MainActor
struct DecisionEnginesAdapterTests {
    private func candidate(_ full: String, score: Double) -> CommandCandidate {
        CommandCandidate(
            source: "history",
            authority: .deterministic,
            suggestion: Suggestion(text: full, displayText: full, fullText: full),
            rawScore: score
        )
    }

    // MARK: - Config persistence

    @Test("Config round-trips through UserDefaults")
    func testConfigRoundTrip() {
        let defaults = testDefaults()
        var config = DecisionEngineConfig()
        config.engineID = .laya
        config.decisionThreshold = 0.85
        config.costPolicy = .freeOnly
        config.layaEndpoint = "http://127.0.0.1:9999"
        config.layaCheckpoint = "multilingual"
        config.save(to: defaults)

        let loaded = DecisionEngineConfig.load(from: defaults)
        #expect(loaded == config)
    }

    @Test("Config defaults are jev, 0.75, any-cost")
    func testConfigDefaults() {
        let loaded = DecisionEngineConfig.load(from: testDefaults())
        #expect(loaded.engineID == .jev)
        #expect(loaded.decisionThreshold == 0.75)
        #expect(loaded.costPolicy == .any)
        #expect(loaded.jevModel == "jev-latest")
    }

    // MARK: - Factory

    @Test("Factory returns literal selection; effective substitutes when Jev key is missing")
    func testFactorySelection() {
        var config = DecisionEngineConfig()
        // Default engine is jev; without a key the effective engine is the
        // deterministic fallback (never a doomed network call).
        #expect(DecisionEngineFactory.makeEffective(config: config, jevAPIKey: "") is DeterministicDecisionEngine)
        #expect(DecisionEngineFactory.make(config: config, jevAPIKey: "k") is JevDecisionEngine)

        config.engineID = .laya
        #expect(DecisionEngineFactory.make(config: config, jevAPIKey: "") is LayaDecisionEngine)
    }

    // MARK: - Jev wire mapping

    @Test("Jev choose maps choice id and confidence")
    func testJevChoose() async throws {
        let log = RequestLog()
        let engine = JevDecisionEngine(
            endpoint: URL(string: "https://api.typesafe.ai")!,
            apiKey: "k",
            transport: FakeTransport(
                json: #"{"answers":{"pick":{"type":"choice","choice":"b","confidence":0.82}}}"#,
                log: log
            )
        )
        let decision = try await engine.choose(
            options: [
                DecisionOption(id: "a", label: "docker ps", localScore: 90),
                DecisionOption(id: "b", label: "docker images", localScore: 80),
            ],
            context: DecisionContext(localConfidence: 0.5, facts: ["state": "typed: docker "])
        )
        #expect(decision.selectedID == "b")
        #expect(decision.confidence == 0.82)

        // Request carries model + labeled criteria.
        let recorded = try #require(log.last)
        let recordedBody = try #require(recorded.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: recordedBody) as? [String: Any])
        #expect(body["model"] as? String == "jev-latest")
        let questions = try #require(body["questions"] as? [String: Any])
        let pick = try #require(questions["pick"] as? [String: Any])
        let criteria = try #require(pick["criteria"] as? [String: String])
        #expect(criteria["b"] == "docker images")
    }

    @Test("Jev none-selection and unknown ids abstain")
    func testJevAbstains() async throws {
        let engine = JevDecisionEngine(
            endpoint: URL(string: "https://api.typesafe.ai")!,
            apiKey: "k",
            transport: FakeTransport(
                json: #"{"answers":{"pick":{"type":"choice","choice":"__none__","confidence":0.4}}}"#
            )
        )
        let decision = try await engine.choose(
            options: [DecisionOption(id: "a", label: "x", localScore: 1)],
            context: DecisionContext(
                localConfidence: 0.5,
                facts: ["state": "s", "allow_none": "true"]
            )
        )
        #expect(decision.selectedID == nil)
    }

    @Test("Jev gate maps noul probability with distance-from-0.5 confidence")
    func testJevGate() async throws {
        let engine = JevDecisionEngine(
            endpoint: URL(string: "https://api.typesafe.ai")!,
            apiKey: "k",
            transport: FakeTransport(json: #"{"answers":{"proceed":{"type":"noul","noul":0.8}}}"#)
        )
        let gate = try await engine.gate(
            question: "Should the suggestion be shown?",
            context: DecisionContext(localConfidence: 0.5, facts: ["state": "s"])
        )
        #expect(gate.shouldProceed)
        #expect(abs(gate.confidence - 0.6) < 0.001)
    }

    @Test("Jev score requires a rubric and parses the value")
    func testJevScore() async throws {
        let engine = JevDecisionEngine(
            endpoint: URL(string: "https://api.typesafe.ai")!,
            apiKey: "k",
            transport: FakeTransport()
        )
        await #expect(throws: DecisionEngineError.missingRubric) {
            try await engine.score(
                option: DecisionOption(id: "a", localScore: 1),
                context: DecisionContext(localConfidence: 0.5, facts: ["state": "s"])
            )
        }

        let graded = JevDecisionEngine(
            endpoint: URL(string: "https://api.typesafe.ai")!,
            apiKey: "k",
            transport: FakeTransport(json: #"{"answers":{"grade":{"type":"score","score":1.7,"confidence":0.7}}}"#)
        )
        let score = try await graded.score(
            option: DecisionOption(id: "a", localScore: 1),
            context: DecisionContext(localConfidence: 0.5, facts: ["state": "s", "levels": "bad|ok|great"])
        )
        #expect(abs(score.score - 1.7) < 0.001)
        #expect(score.confidence == 0.7)
    }

    @Test("Jev without key and missing state throw before any network use")
    func testJevPreconditions() async throws {
        let log = RequestLog()
        let noKey = JevDecisionEngine(
            endpoint: URL(string: "https://api.typesafe.ai")!, apiKey: "",
            transport: FakeTransport(log: log)
        )
        await #expect(throws: DecisionEngineError.missingAPIKey) {
            try await noKey.choose(
                options: [DecisionOption(id: "a", localScore: 1)],
                context: DecisionContext(localConfidence: 0.5, facts: ["state": "s"])
            )
        }
        let noState = JevDecisionEngine(
            endpoint: URL(string: "https://api.typesafe.ai")!, apiKey: "k",
            transport: FakeTransport(log: log)
        )
        await #expect(throws: DecisionEngineError.missingState) {
            try await noState.choose(
                options: [DecisionOption(id: "a", localScore: 1)],
                context: DecisionContext(localConfidence: 0.5)
            )
        }
        #expect(log.count == 0)
    }

    // MARK: - Laya wire mapping

    @Test("Laya posts to /v1/decide with checkpoint and health-probes /v1/health")
    func testLayaWire() async throws {
        let log = RequestLog()
        let engine = LayaDecisionEngine(
            endpoint: URL(string: "http://127.0.0.1:8765")!,
            checkpoint: "multilingual",
            transport: FakeTransport(
                json: #"{"answers":{"pick":{"type":"choice","choice":"a","confidence":0.17,"probabilities":{"a":0.63,"b":0.2,"c":0.17}}}}"#,
                log: log
            )
        )
        let decision = try await engine.choose(
            options: [DecisionOption(id: "a", label: "kubectl get pods", localScore: 90)],
            context: DecisionContext(localConfidence: 0.5, facts: ["state": "typed: kubectl "])
        )
        #expect(decision.selectedID == "a")
        // Laya gates on the winner's top-1 probability (0.63), not the
        // uncalibrated reported confidence (0.17).
        #expect(abs(decision.confidence - 0.63) < 0.001)
        let recorded = try #require(log.last)
        #expect(recorded.url?.path == "/v1/decide")
        let recordedBody = try #require(recorded.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: recordedBody) as? [String: Any])
        #expect(body["checkpoint"] as? String == "multilingual")

        let healthLog = RequestLog()
        let healthy = LayaDecisionEngine(
            endpoint: URL(string: "http://127.0.0.1:8765")!,
            transport: FakeTransport(status: 200, json: #"{"ok":true}"#, log: healthLog)
        )
        try await healthy.checkHealth()
        #expect(healthLog.last?.url?.path == "/v1/health")

        let down = LayaDecisionEngine(
            endpoint: URL(string: "http://127.0.0.1:8765")!,
            transport: FakeTransport(status: 503)
        )
        await #expect(throws: DecisionEngineError.self) {
            try await down.checkHealth()
        }
    }

    // MARK: - Decision traces

    @Test("decideBest records engine, winner, confidence, latency, and order change")
    func testDecideBestRecordsTrace() async throws {
        let recorder = DecisionTraceRecorder()
        let engine = CommandDecisionEngine()
        let pool = [
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: " ps", displayText: " ps", fullText: "docker ps"),
                rawScore: 90.0
            ),
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: " images", displayText: " images", fullText: "docker images"),
                rawScore: 80.0
            ),
        ]
        let flaky = FlakyDecisionEngine(selection: pool[1].id, confidence: 0.9)
        let reordered = await engine.decideBest(
            candidates: pool, typed: "docker ", state: "",
            engine: flaky, decisionThreshold: 0.75, recorder: recorder
        )
        #expect(reordered?.first?.fullText == "docker images")

        let summary = await recorder.summary()
        let stats = try #require(summary["flaky"])
        #expect(stats.decisions == 1)
        #expect(stats.reorders == 1)
        #expect(stats.reorderRate == 1.0)
        #expect(stats.meanLatencyMs >= 0)

        let traces = await recorder.recentTraces()
        let trace = try #require(traces.first)
        #expect(trace.originalTopID == pool[0].id)
        #expect(trace.selectedID == pool[1].id)
        #expect(trace.confidenceSource == "flaky")
        #expect(trace.changedOrder)
    }

    @Test("Top pick records no order change; accepts attribute per engine")
    func testTraceNoChangeAndAccepts() async throws {
        let recorder = DecisionTraceRecorder()
        let engine = CommandDecisionEngine()
        let pool = [
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: " ps", displayText: " ps", fullText: "docker ps"),
                rawScore: 90.0
            ),
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: " images", displayText: " images", fullText: "docker images"),
                rawScore: 80.0
            ),
        ]
        let flaky = FlakyDecisionEngine(selection: pool[0].id, confidence: 0.95)
        _ = await engine.decideBest(
            candidates: pool, typed: "docker ", state: "",
            engine: flaky, decisionThreshold: 0.75, recorder: recorder
        )
        await recorder.recordAccept(engine: "flaky")

        let summary = await recorder.summary()
        let stats = try #require(summary["flaky"])
        #expect(stats.reorders == 0)
        #expect(stats.reorderRate == 0)
        #expect(stats.accepts == 1)
    }

    @Test("Calibration buckets map predicted bands to observed accept rates")
    func testCalibrationBuckets() async throws {
        let recorder = DecisionTraceRecorder()
        let engine = CommandDecisionEngine()
        let pool = [
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: " ps", displayText: " ps", fullText: "docker ps"),
                rawScore: 90.0
            ),
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: " images", displayText: " images", fullText: "docker images"),
                rawScore: 80.0
            ),
        ]
        // High-confidence pick, then accepted: 0.9 band goes 1/1.
        let confident = FlakyDecisionEngine(selection: pool[1].id, confidence: 0.9)
        _ = await engine.decideBest(
            candidates: pool, typed: "docker ", state: "",
            engine: confident, decisionThreshold: 0.5, recorder: recorder
        )
        await recorder.recordAccept(engine: "flaky", selectedID: pool[1].id)

        let buckets = await recorder.calibrationBuckets()
        let flaky = try #require(buckets["flaky"])
        #expect(flaky.count == 5)
        let top = try #require(flaky.last)
        #expect(top.lowerBound == 0.9)
        #expect(top.decisions == 1)
        #expect(top.accepts == 1)
        #expect(top.acceptRate == 1.0)
        #expect(flaky.first?.accepts == 0)
    }

    // MARK: - decideBest threshold gate

    @Test("decideBest reorders on confident pick, keeps order on weak pick")
    func testDecideBestThreshold() async throws {
        let engine = CommandDecisionEngine()
        let pool = [candidate("docker ps", score: 90), candidate("docker images", score: 80)]

        let confident = FlakyDecisionEngine(selection: pool[1].id, confidence: 0.9)
        let reordered = await engine.decideBest(
            candidates: pool, typed: "docker ", state: "",
            engine: confident, decisionThreshold: 0.75
        )
        #expect(reordered?.first?.fullText == "docker images")
        #expect(reordered?.count == 2) // Nothing invented, nothing dropped.

        let weak = FlakyDecisionEngine(selection: pool[1].id, confidence: 0.2)
        #expect(await engine.decideBest(
            candidates: pool, typed: "docker ", state: "",
            engine: weak, decisionThreshold: 0.75
        ) == nil)

        #expect(await engine.decideBest(
            candidates: [pool[0]], typed: "docker ", state: "",
            engine: confident, decisionThreshold: 0.75
        ) == nil)
    }
}
