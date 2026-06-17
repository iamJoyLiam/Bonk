//
//  AIProviderDetailSheet+Networking.swift
//  Bonk
//
//  Network operations and Copilot actions for AIProviderDetailSheet.
//

import SwiftUI

// MARK: - Networking

extension AIProviderDetailSheet {
    func cancelTasks() {
        modelFetchTask?.cancel()
        modelFetchTask = nil
    }

    func scheduleFetchModels() {
        modelFetchTask?.cancel()
        modelFetchTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            fetchModels()
        }
    }

    func fetchModels() {
        guard draft.type.needsAPIKey || draft.type == .ollama else {
            return
        }
        if draft.type.needsAPIKey, draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fetchedModels = []; modelFetchError = nil; return
        }
        guard let url = AIProviderNetworking.modelsURL(
            endpoint: draft.endpoint, type: draft.type, apiKey: draft.apiKey
        ) else { return }

        isFetchingModels = true; modelFetchError = nil
        modelFetchTask?.cancel()
        modelFetchTask = Task {
            do {
                let request = AIProviderNetworking.makeRequest(url: url, apiKey: draft.apiKey, type: draft.type)
                let models = try await AIProviderNetworking.fetchModels(request: request, type: draft.type)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    fetchedModels = models
                    // Persist to shared store so sidebar can access
                    AIProviderStore.shared.cachedModels[draft.id] = models
                    if draft.model.isEmpty, let first = models.first { draft.model = first }
                    isFetchingModels = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { modelFetchError = error.localizedDescription; isFetchingModels = false }
            }
        }
    }

    func testProvider() {
        let trimmed = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { testResult = .failure(i18n.t(.apiKeyRequired)); return }

        isTesting = true; testResult = nil
        Task {
            do {
                let isSuccess: Bool
                if draft.type == .custom {
                    isSuccess = try await testCustomProvider()
                } else {
                    guard let url = AIProviderNetworking.modelsURL(
                        endpoint: draft.endpoint, type: draft.type, apiKey: draft.apiKey
                    ) else {
                        await MainActor.run { isTesting = false; testResult = .failure(i18n.t(.connectionTestFailed)) }
                        return
                    }
                    let request = AIProviderNetworking.makeRequest(url: url, apiKey: draft.apiKey, type: draft.type)
                    isSuccess = try await AIProviderNetworking.testConnection(request: request)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTesting = false
                    testResult = isSuccess ? .success : .failure(i18n.t(.connectionTestFailed))
                    if isSuccess, draft.type != .custom { fetchModels() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { isTesting = false; testResult = .failure(error.localizedDescription) }
            }
        }
    }

    /// Test a custom provider by sending a minimal POST request.
    /// Distinguishes auth errors (bad key) from model errors (endpoint+key valid).
    private func testCustomProvider() async throws -> Bool {
        let base = AIProviderNetworking.baseEndpoint(draft.endpoint)
        guard let url = URL(string: base + "/v1/chat/completions") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !draft.apiKey.isEmpty {
            request.setValue("Bearer \(draft.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }

        // 2xx–3xx: endpoint and key are valid
        if http.statusCode < 400 { return true }

        // 401/403: auth failure — endpoint reachable but key is wrong
        if http.statusCode == 401 || http.statusCode == 403 { return false }

        // Other 4xx/5xx: check if the error is about the model (not auth).
        // If so, the endpoint and key are valid — just the test model doesn't exist.
        if let body = String(data: data, encoding: .utf8)?.lowercased() {
            let modelRelated = body.contains("model") || body.contains("not found")
                || body.contains("invalid_request") || body.contains("does not exist")
            if modelRelated { return true }
        }

        return false
    }
}

// MARK: - Copilot Actions

extension AIProviderDetailSheet {
    func copilotSignIn() async {
        do { try await copilotService.signIn() } catch {
            copilotService.errorMessage = error.localizedDescription
        }
    }

    func copilotCompleteSignIn() async {
        do { try await copilotService.completeSignIn() } catch {
            copilotService.errorMessage = error.localizedDescription
        }
    }
}
