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
                    if let provider = store.activeProvider,
                       store.cachedModels[provider.id] == nil
                    {
                        store.fetchModels(for: provider)
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
                let noModel = selectedModel.isEmpty

                if noModel, store.cachedModels[provider.id] == nil {
                    EmptyView()
                } else if let models = store.cachedModels[provider.id], !models.isEmpty {
                    ForEach(models, id: \.self) { model in
                        Button {
                            var updated = provider
                            updated.model = model
                            store.update(updated)
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
}

// MARK: - Sidebar extension

extension AIChatSidebarView {
    var modelMenu: some View {
        ModelPickerButton(store: providerStore)
    }
}
