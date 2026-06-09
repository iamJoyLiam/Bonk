import SwiftUI

// MARK: - Model Menu (standalone view — no overlap, no marquee)

/// Isolated model picker view. Reads from shared AIProviderStore.
/// Uses HStack+onTapGesture (not Button) to avoid macOS marquee.
struct ModelPickerButton: View {
    @ObservedObject var store: AIProviderStore
    @State private var isOpen = false

    var body: some View {
        let provider = store.activeProvider
        let name = provider?.model ?? ""
        let displayName = name.isEmpty ? (provider?.type.displayName ?? "") : name

        HStack(spacing: 4) {
            Text(displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 7))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Capsule())
        .onTapGesture { isOpen.toggle() }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            modelList.frame(width: 220)
                .onAppear {
                    // Auto-fetch if cache is empty
                    if let provider = store.activeProvider,
                       store.cachedModels[provider.id] == nil {
                        fetchModels(for: provider)
                    }
                }
        }
    }

    private var modelList: some View {
        let activeID = store.activeProviderID
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(store.providers, id: \.id) { provider in
                let isActive = provider.id == activeID
                let selectedModel = provider.model
                let cachedModels = store.cachedModels[provider.id]
                let hasCache = cachedModels != nil && !cachedModels!.isEmpty
                let noModel = selectedModel.isEmpty

                if noModel && !hasCache {
                    // No model configured — skip (shouldn't happen after validation)
                    EmptyView()
                } else if hasCache {
                    // Has cached models → show full list
                    ForEach(cachedModels!, id: \.self) { model in
                        Button {
                            var p = provider
                            p.model = model
                            store.update(p)
                            store.setActive(provider.id)
                            isOpen = false
                        } label: {
                            HStack {
                                Text(model).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                if model == selectedModel, isActive {
                                    Image(systemName: "checkmark").font(.system(size: 10))
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    // Has configured model but no cache → show only that model
                    Button {
                        store.setActive(provider.id)
                        isOpen = false
                    } label: {
                        HStack {
                            Text(selectedModel).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            if isActive {
                                Image(systemName: "checkmark").font(.system(size: 10))
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func fetchModels(for provider: AIProviderConfig) {
        guard let url = AIProviderNetworking.modelsURL(
            endpoint: provider.endpoint, type: provider.type, apiKey: provider.apiKey
        ) else { return }
        Task {
            do {
                let request = AIProviderNetworking.makeRequest(
                    url: url, apiKey: provider.apiKey, type: provider.type
                )
                let models = try await AIProviderNetworking.fetchModels(
                    request: request, type: provider.type
                )
                await MainActor.run {
                    store.cachedModels[provider.id] = models
                }
            } catch {
                // Silently fail — will show configured model only
            }
        }
    }
}

// MARK: - Sidebar extension

extension AIChatSidebarView {
    var modelMenu: some View {
        ModelPickerButton(store: providerStore)
    }
}
