import Foundation

/// Networking helpers for AI provider API interactions.
enum AIProviderNetworking {
    private static let anthropicVersion = "2023-06-01"

    // MARK: - Build API Request

    static func makeRequest(url: URL, apiKey: String, type: AIProviderType) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if type.needsAPIKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if type == .claude {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
        if type == .gemini {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }

    // MARK: - Models URL

    static func modelsURL(endpoint: String, type: AIProviderType, apiKey _: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }

        switch type {
        case .openAI, .openRouter, .openCode, .claude:
            components.path = components.path.trimmingSuffix("/") + "/v1/models"
        case .gemini:
            components.path = components.path.trimmingSuffix("/") + "/v1beta/models"
        case .ollama:
            components.path = components.path.trimmingSuffix("/") + "/api/tags"
        case .copilot, .custom:
            return nil
        }

        return components.url
    }

    // MARK: - Fetch Models

    static func fetchModels(request: URLRequest, type: AIProviderType) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }

        return try parseModels(from: data, type: type)
    }

    // MARK: - Test Connection

    static func testConnection(request: URLRequest) async throws -> Bool {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            return http.statusCode < 400
        }
        return false
    }

    // MARK: - Parse Models

    private static func parseModels(from data: Data, type: AIProviderType) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // OpenAI / OpenRouter / OpenCode / Claude: { "data": [{ "id": "..." }] }
        if let data = json?["data"] as? [[String: Any]] {
            return data.compactMap { $0["id"] as? String }.sorted()
        }

        // Ollama / Gemini: { "models": [{ "name": "..." }] }
        if let models = json?["models"] as? [[String: Any]] {
            return models.compactMap { item -> String? in
                guard let name = item["name"] as? String else { return nil }
                // Gemini names are prefixed with "models/"
                if type == .gemini {
                    return name.replacingOccurrences(of: "models/", with: "")
                }
                return name
            }.sorted()
        }

        return []
    }
}

// MARK: - String Helper

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
