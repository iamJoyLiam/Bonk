//  SystemOneClient.swift
//  Bonk
//
//  Shared HTTP transport for System-One-style decision endpoints:
//  TypeSafe Jev (POST {endpoint}/v1/systemone, Bearer key) and a local Laya
//  bridge (POST {endpoint}/v1/decide, same question/answer shapes — see
//  bonk-laya-bridge.py). Maps DecisionEngine calls to typed questions and
//  typed answers back. Any transport failure throws; callers fall back to
//  deterministic order.

import Foundation

enum DecisionEngineError: Error, Equatable {
    case missingAPIKey
    case missingState
    case missingRubric
    case badResponse(String)
    case httpError(Int)
    case unhealthy(String)
}

extension DecisionEngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is required — enter it in Settings → Decision Engine first."
        case .missingState:
            return "No input state was provided for the decision."
        case .missingRubric:
            return "Score needs an ordered level rubric (levels=a|b|c)."
        case let .badResponse(detail):
            return "The decision service returned an unreadable response (\(detail))."
        case let .httpError(code):
            if code == 401 {
                return "Unauthorized (HTTP 401) — check the API key."
            }
            return "The decision service failed (HTTP \(code))."
        case let .unhealthy(detail):
            return "The decision service is unreachable (\(detail)). Is it running?"
        }
    }
}

// MARK: - Wire models (TypeSafe SystemOne shape)

struct SystemOneQuestion: Encodable {
    let type: String // "choice" | "noul" | "score"
    let instructions: String
    let criteria: SystemOneCriteria?

    enum SystemOneCriteria: Encodable {
        case options([String: String])
        case levels([String])

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .options(map): try container.encode(map)
            case let .levels(list): try container.encode(list)
            }
        }
    }
}

struct SystemOneRequest: Encodable {
    let state: String
    let model: String
    let questions: [String: SystemOneQuestion]
}

struct SystemOneAnswer: Decodable {
    let type: String?
    let choice: String?
    let confidence: Double?
    let noul: Double?
    let score: Double?
    let probabilities: [String: Double]?

    /// Top-1 probability for a Choice answer (keyed by the chosen option).
    var topProbability: Double? {
        guard let choice else { return nil }
        return probabilities?[choice]
    }
}

struct SystemOneResponse: Decodable {
    let answers: [String: SystemOneAnswer]
}

/// Transport seam. URLSession conforms in production; tests inject a fake.
/// Instance-scoped on purpose: no global stub state, parallel-safe.
protocol SystemOneTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: SystemOneTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

// MARK: - Client

/// Minimal SystemOne transport. No global state; parallel-safe.
struct SystemOneClient: Sendable {
    let endpoint: URL
    let path: String
    /// Extra model selector sent alongside questions. Jev uses "model";
    /// the Laya bridge uses "checkpoint" (empty = router auto).
    let modelField: String
    let modelValue: String
    let bearerKey: String?
    let timeoutSeconds: Double
    let transport: any SystemOneTransport

    init(
        endpoint: URL,
        path: String,
        modelField: String = "model",
        modelValue: String,
        bearerKey: String? = nil,
        timeoutSeconds: Double,
        transport: any SystemOneTransport = URLSession.shared
    ) {
        self.endpoint = endpoint
        self.path = path
        self.modelField = modelField
        self.modelValue = modelValue
        self.bearerKey = bearerKey
        self.timeoutSeconds = timeoutSeconds
        self.transport = transport
    }

    func ask(state: String, questions: [String: SystemOneQuestion]) async throws -> [String: SystemOneAnswer] {
        let encoder = JSONEncoder()
        let questionsData = try encoder.encode(questions)
        let questionsJSON = try JSONSerialization.jsonObject(with: questionsData) as? [String: Any] ?? [:]
        let body: [String: Any] = [
            "state": state,
            modelField: modelValue,
            "questions": questionsJSON,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = bearerKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeoutSeconds

        let (data, response) = try await transport.send(request)
        guard let http = response as? HTTPURLResponse else {
            throw DecisionEngineError.badResponse("non-HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw DecisionEngineError.httpError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(SystemOneResponse.self, from: data).answers
        } catch {
            #if DEBUG
                let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
                print("[SystemOne] decode failed: \(error.localizedDescription) body=\(preview)")
            #endif
            throw DecisionEngineError.badResponse(error.localizedDescription)
        }
    }

    /// Liveness probe. Jev: GET /v1/models (auth required). Laya bridge:
    /// GET /v1/health (no auth).
    func checkHealth(healthPath: String) async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent(healthPath))
        request.httpMethod = "GET"
        if let key = bearerKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = min(timeoutSeconds, 5)
        let (_, response) = try await transport.send(request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw DecisionEngineError.unhealthy(healthPath)
        }
    }
}

// MARK: - Question mapping (shared by Jev and Laya adapters)

enum SystemOneMapping {
    static let noneOptionID = "__none__"

    /// Choice over code-produced options. Labels carry meaning for the model;
    /// ids are the stable contract back to code.
    static func choiceQuestion(options: [DecisionOption], instructions: String, allowNone: Bool) -> SystemOneQuestion {
        var criteria: [String: String] = [:]
        for option in options {
            criteria[option.id] = option.label.isEmpty ? option.id : option.label
        }
        if allowNone {
            criteria[noneOptionID] = "None of the options fit"
        }
        return SystemOneQuestion(type: "choice", instructions: instructions, criteria: .options(criteria))
    }

    static func interpretChoice(
        _ answer: SystemOneAnswer?,
        validIDs: Set<String>
    ) -> (selectedID: String?, confidence: Double) {
        guard let answer, let picked = answer.choice else { return (nil, 0) }
        guard picked != noneOptionID, validIDs.contains(picked) else {
            return (nil, answer.confidence ?? 0)
        }
        return (picked, answer.confidence ?? 0)
    }
}
