import SwiftUI

// MARK: - Model Menu & Operations

extension AIChatSidebarView {

    var modelMenu: some View {
        let currentModel = activeProvider?.model ?? i18n.t(.aiNoModel)
        return Menu {
            if isFetchingModels {
                Text(i18n.t(.aiFetchingModels))
            } else if fetchedModels.isEmpty {
                Button { fetchModels() } label: {
                    Label(i18n.t(.aiFetchModels), systemImage: "arrow.clockwise")
                }
            } else {
                ForEach(fetchedModels, id: \.self) { model in
                    Button { applyModel(model) } label: {
                        Label(model, systemImage: model == currentModel ? "checkmark" : "")
                    }
                }
            }

            Divider()

            // Switch provider
            ForEach(allProviders) { provider in
                let isActive = provider.id.uuidString == activeProvider?.id.uuidString
                Button { switchToProvider(provider) } label: {
                    Label("\(provider.name) — \(provider.model)", systemImage: isActive ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.system(size: 11))
                Text(currentModel).font(.system(size: 11))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 120)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(nsColor: .controlColor)).clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .onAppear { fetchModels() }
    }

    var activeProvider: AIProviderConfig? {
        AIProviderStore.activeProvider
    }

    var allProviders: [AIProviderConfig] {
        AIProviderStore.allProviders
    }

    func fetchModels() {
        guard let provider = activeProvider,
              let url = AIProviderNetworking.modelsURL(
                  endpoint: provider.endpoint,
                  type: provider.type,
                  apiKey: provider.apiKey
              ) else { return }
        isFetchingModels = true
        Task {
            do {
                let request = AIProviderNetworking.makeRequest(url: url, apiKey: provider.apiKey, type: provider.type)
                let models = try await AIProviderNetworking.fetchModels(request: request, type: provider.type)
                await MainActor.run { fetchedModels = models; isFetchingModels = false }
            } catch {
                await MainActor.run { isFetchingModels = false }
            }
        }
    }

    func switchToProvider(_ provider: AIProviderConfig) {
        UserDefaults.standard.set(provider.id.uuidString, forKey: "ai_active_provider_id")
        fetchedModels = []
        fetchModels()
    }

    func applyModel(_ model: String) {
        guard var provider = activeProvider else { return }
        provider.model = model.trimmingCharacters(in: .whitespaces)
        AIProviderStore.updateProvider(provider)
    }
}
