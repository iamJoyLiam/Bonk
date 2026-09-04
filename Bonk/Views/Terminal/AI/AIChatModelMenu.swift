import SwiftUI

// MARK: - Model Menu (standalone view — no overlap, no marquee)

/// Isolated model picker view. Reads from shared AIProviderStore.
/// Uses HStack+onTapGesture (not Button) to avoid macOS marquee.
struct ModelPickerButton: View {
    @Bindable var store: AIProviderStore
    @State private var isOpen = false

    var body: some View {
        let provider = store.activeProvider
        let name = provider?.model ?? ""
        let displayName = name.isEmpty ? (provider?.type.displayName ?? "") : name

        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: AppStyle.fontMicro))
            Text(displayName)
                .font(.system(size: AppStyle.fontSmall))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: AppStyle.fontMicro))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture { isOpen.toggle() }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            let provider = store.activeProvider
            let models = provider.flatMap { store.cachedModels[$0.id] } ?? []
            let rowCount = models.isEmpty ? 1 : models.count
            let height = min(320, max(44, CGFloat(rowCount) * 24 + 12))
            ScrollView(.vertical) {
                modelList
            }
            .frame(width: AppStyle.size220, height: height)
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
        // Only the ACTIVE provider's models belong in this menu.
        guard let provider = store.activeProvider else {
            return AnyView(Text("—").font(.system(size: AppStyle.fontBody)).foregroundStyle(.secondary).padding(AppStyle.spacingM))
        }
        let selectedModel = provider.model
        let models = store.cachedModels[provider.id] ?? []

        return AnyView(VStack(alignment: .leading, spacing: 0) {
            if !models.isEmpty {
                ForEach(models, id: \.self) { model in
                    Button {
                        var updated = provider
                        updated.model = model
                        store.update(updated)
                        store.setActive(provider.id)
                        isOpen = false
                    } label: {
                        HStack {
                            Text(model).font(.system(size: AppStyle.fontBody)).lineLimit(1)
                            Spacer()
                            if model == selectedModel {
                                Image(systemName: "checkmark").font(.system(size: AppStyle.fontCaption))
                            }
                        }
                        .padding(.horizontal, AppStyle.spacingML).padding(.vertical, AppStyle.spacingSPlus)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else if !selectedModel.isEmpty {
                // Configured model but no cached list → show it only.
                Button {
                    store.setActive(provider.id)
                    isOpen = false
                } label: {
                    HStack {
                        Text(selectedModel).font(.system(size: AppStyle.fontBody)).lineLimit(1)
                        Spacer()
                        Image(systemName: "checkmark").font(.system(size: AppStyle.fontCaption))
                    }
                    .padding(.horizontal, AppStyle.spacingML).padding(.vertical, AppStyle.spacingSPlus)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text("—").font(.system(size: AppStyle.fontBody)).foregroundStyle(.secondary).padding(AppStyle.spacingM)
            }
        }
        .padding(.vertical, AppStyle.spacingS))
    }
}

// MARK: - Sidebar extension

extension AIChatSidebarView {
    var modelMenu: some View {
        ModelPickerButton(store: providerStore)
    }
}
