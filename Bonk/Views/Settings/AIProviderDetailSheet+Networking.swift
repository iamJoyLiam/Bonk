//
//  AIProviderDetailSheet+Networking.swift
//  Bonk
//
//  Network operations for AIProviderDetailSheet.
//

import SwiftUI

// MARK: - Networking

extension AIProviderDetailSheet {
    func cancelTasks() {
        modelFetchTask?.cancel()
        modelFetchTask = nil
    }

    func scheduleFetchModels() {
        syncHeadersToDraft()
        modelFetchTask?.cancel()
        modelFetchTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            fetchModels()
        }
    }

    func fetchModels() {
        syncHeadersToDraft()
        guard draft.type.needsAPIKey || draft.type == .ollama || draft.type == .custom else {
            return
        }
        if draft.type.needsAPIKey, draft.type != .custom,
           draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            fetchedModels = []; modelFetchError = nil; return
        }

        isFetchingModels = true; modelFetchError = nil
        modelFetchTask?.cancel()
        modelFetchTask = Task {
            do {
                let llm = LLMProviderFactory.provider(for: draft, apiKey: draft.apiKey)
                let models = try await llm.listModels()
                await AIProviderCapabilityProbe.refresh(
                    provider: draft,
                    apiKey: draft.apiKey
                )
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
        syncHeadersToDraft()
        let trimmed = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // litellm / local OpenAI-compatible proxies often run without a key;
        // only enforce the key for providers that require authentication.
        if draft.type != .custom, trimmed.isEmpty {
            testResult = .failure(i18n.t(.apiKeyRequired))
            return
        }

        isTesting = true; testResult = nil
        Task {
            do {
                let isSuccess: Bool
                if draft.type == .custom || draft.protocolType == .responses {
                    isSuccess = try await testCustomProvider()
                } else {
                    let llm = LLMProviderFactory.provider(for: draft, apiKey: draft.apiKey)
                    isSuccess = try await llm.testConnection()
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTesting = false
                    testResult = isSuccess ? .success : .failure(i18n.t(.connectionTestFailed))
                    if isSuccess { fetchModels() }
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
        let path = draft.protocolType == .responses ? "/v1/responses" : "/v1/chat/completions"
        guard !base.isEmpty, let url = URL(string: base + path) else {
            throw NSError(
                domain: "Bonk.AI",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "无效的端点地址：\(draft.endpoint)"]
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !draft.apiKey.isEmpty {
            request.setValue("Bearer \(draft.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in draft.extraHeaders where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.isEmpty ? "test" : model
        let body: [String: Any] = if draft.protocolType == .responses {
            [
                "model": resolvedModel,
                "input": "hi",
                "max_output_tokens": 1,
            ]
        } else {
            [
                "model": resolvedModel,
                "messages": [["role": "user", "content": "hi"]],
                "max_tokens": 1,
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "Bonk.AI",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: i18n.t(.connectionTestFailed)]
            )
        }

        // 2xx–3xx: endpoint and key are valid
        if http.statusCode < 400 { return true }

        let errorBody = String(data: data, encoding: .utf8) ?? ""
        let lower = errorBody.lowercased()

        // 401/403: auth failure — endpoint reachable but key is missing/wrong
        if http.statusCode == 401 || http.statusCode == 403 {
            throw NSError(
                domain: "Bonk.AI",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "认证失败（HTTP \(http.statusCode)）：检查 API Key（litellm 需填 master_key）",
                ]
            )
        }

        // Other 4xx/5xx: check if the error is about the model (not auth).
        // If so, the endpoint and key are valid — just the test model doesn't exist.
        let modelRelated = lower.contains("model") || lower.contains("not found")
            || lower.contains("invalid_request") || lower.contains("does not exist")
        if modelRelated { return true }

        throw NSError(
            domain: "Bonk.AI",
            code: http.statusCode,
            userInfo: [
                NSLocalizedDescriptionKey: "连接测试失败（HTTP \(http.statusCode)）：\(String(errorBody.prefix(300)))",
            ]
        )
    }
}
