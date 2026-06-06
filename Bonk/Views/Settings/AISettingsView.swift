import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject var i18n: I18n
    @AppStorage("ai_enabled") private var aiEnabled = false
    @AppStorage("ai_inline_suggestions") private var inlineSuggestionsEnabled = false
    @AppStorage("ai_debounce_ms") private var inlineSuggestionDebounceMs = 500
    @AppStorage("ai_include_terminal") private var includeTerminalOutput = true
    @AppStorage("ai_include_history") private var includeCommandHistory = true
    @AppStorage("ai_include_env") private var includeEnvironmentInfo = false
    @AppStorage("ai_connection_policy") private var defaultConnectionPolicyRaw = "askEachTime"

    @StateObject private var store = AIProviderStore()

    @State private var editingProviderID: UUID?
    @State private var addingProviderType: AIProviderType?
    @State private var pendingDeleteID: UUID?

    private let debounceRange = 100 ... 3000

    private var defaultConnectionPolicy: AIConnectionPolicy {
        get { AIConnectionPolicy(rawValue: defaultConnectionPolicyRaw) ?? .askEachTime }
        set { defaultConnectionPolicyRaw = newValue.rawValue }
    }

    var body: some View {
        Form {
            // Enable
            Section {
                Toggle(i18n.t(.enableAIFeatures), isOn: $aiEnabled)
            }

            if aiEnabled {
                // Active Provider
                activeProviderSection

                // Providers
                providersSection

                // Inline Suggestions
                inlineSuggestionsSection

                // Context
                contextSection

                // Privacy
                privacySection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: editingSheetBinding) {
            if let id = editingProviderID,
               let provider = store.providers.first(where: { $0.id == id }) {
                AIProviderDetailSheet(
                    provider: provider,
                    isNew: false,
                    onSave: { saved in
                        store.update(saved)
                        editingProviderID = nil
                    },
                    onDelete: {
                        pendingDeleteID = provider.id
                        editingProviderID = nil
                    },
                    onCancel: { editingProviderID = nil }
                )
            }
        }
        .sheet(isPresented: addingSheetBinding) {
            if let type = addingProviderType {
                AIProviderDetailSheet(
                    provider: AIProviderConfig(type: type),
                    isNew: true,
                    onSave: { saved in
                        store.add(saved)
                        if store.activeProviderID == nil { store.setActive(saved.id) }
                        addingProviderType = nil
                    },
                    onDelete: nil,
                    onCancel: { addingProviderType = nil }
                )
            }
        }
        .alert(i18n.t(.removeProviderQ), isPresented: deleteAlertBinding) {
            Button(i18n.t(.remove), role: .destructive) {
                if let id = pendingDeleteID { store.remove(id) }
                pendingDeleteID = nil
            }
            Button(i18n.t(.cancel), role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text(i18n.t(.apiKeyDeleted))
        }
    }

    // MARK: - Active Provider

    private var activeProviderSection: some View {
        Section {
            HStack {
                Text(i18n.t(.activeProvider))
                Spacer()
                Picker("", selection: $store.activeProviderID) {
                    Text(i18n.t(.none)).tag(UUID?.none)
                    ForEach(store.providers) { provider in
                        Text(provider.displayName).tag(UUID?.some(provider.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(store.providers.isEmpty)
                .onChange(of: store.activeProviderID) { _, _ in store.save() }
            }
        }
    }

    // MARK: - Providers

    private var providersSection: some View {
        Section {
            if store.providers.isEmpty {
                HStack {
                    Spacer()
                    Text(i18n.t(.noProvidersConfigured))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
                .padding(.vertical, 6)
            } else {
                ForEach(store.providers) { provider in
                    providerRow(provider)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingProviderID = provider.id
                        }
                        .contextMenu {
                            Button(i18n.t(.edit)) { editingProviderID = provider.id }
                            Button(i18n.t(.setAsActive)) { store.setActive(provider.id) }
                                .disabled(store.activeProviderID == provider.id)
                            Divider()
                            Button(i18n.t(.remove), role: .destructive) { pendingDeleteID = provider.id }
                        }
                }
            }
            addProviderMenu
        } header: {
            Text(i18n.t(.providers))
        }
    }

    private func providerRow(_ provider: AIProviderConfig) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if provider.id == store.activeProviderID {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 14)

            Image(systemName: provider.type.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .fontWeight(.regular)
                Text(providerStatusText(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func providerStatusText(_ provider: AIProviderConfig) -> String {
        if provider.hasAPIKey { return i18n.t(.apiKeySet) }
        if provider.type == .ollama { return i18n.t(.local) }
        if !provider.endpoint.isEmpty {
            if let host = URL(string: provider.endpoint)?.host { return host }
            return provider.endpoint
        }
        return i18n.t(.notConfigured)
    }

    private var addProviderMenu: some View {
        Menu {
            ForEach(orderedAddableTypes, id: \.self) { type in
                Button { addingProviderType = type } label: {
                    Label(type.displayName, systemImage: type.symbolName)
                }
            }
            Divider()
            Button { addingProviderType = .custom } label: {
                Label(i18n.t(.addCustomProvider), systemImage: AIProviderType.custom.symbolName)
            }
        } label: {
            Label(i18n.t(.addProvider), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var orderedAddableTypes: [AIProviderType] {
        [.copilot, .claude, .openAI, .openRouter, .openCode, .gemini, .ollama]
    }

    // MARK: - Inline Suggestions

    private var inlineSuggestionsSection: some View {
        Section {
            Toggle(i18n.t(.enableInlineSuggestions), isOn: $inlineSuggestionsEnabled)
                .disabled(store.activeProviderID == nil)
                .help(store.activeProviderID != nil ? "" : i18n.t(.configureProviderHint))
            Stepper(
                i18n.t(.debounce) + ": \(inlineSuggestionDebounceMs) ms",
                value: debounceBinding,
                in: debounceRange,
                step: 50
            )
            .disabled(!inlineSuggestionsEnabled)
        } header: {
            Text(i18n.t(.inlineSuggestions))
        } footer: {
            Text(i18n.t(.inlineSuggestionsFooter))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Context

    private var contextSection: some View {
        Section {
            Toggle(i18n.t(.includeTerminalOutput), isOn: $includeTerminalOutput)
            Toggle(i18n.t(.includeCommandHistory), isOn: $includeCommandHistory)
            Toggle(i18n.t(.includeEnvInfo), isOn: $includeEnvironmentInfo)
        } header: {
            Text(i18n.t(.context))
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            Picker(i18n.t(.connectionPolicy), selection: connectionPolicyBinding) {
                ForEach(AIConnectionPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text(i18n.t(.privacy))
        }
    }

    private var debounceBinding: Binding<Int> {
        Binding(
            get: { inlineSuggestionDebounceMs },
            set: { inlineSuggestionDebounceMs = min(max($0, debounceRange.lowerBound), debounceRange.upperBound) }
        )
    }

    private var connectionPolicyBinding: Binding<AIConnectionPolicy> {
        Binding<AIConnectionPolicy>(
            get: { AIConnectionPolicy(rawValue: defaultConnectionPolicyRaw) ?? .askEachTime },
            set: { defaultConnectionPolicyRaw = $0.rawValue }
        )
    }

    // MARK: - Helpers

    private var editingSheetBinding: Binding<Bool> {
        Binding(get: { editingProviderID != nil }, set: { if !$0 { editingProviderID = nil } })
    }

    private var addingSheetBinding: Binding<Bool> {
        Binding(get: { addingProviderType != nil }, set: { if !$0 { addingProviderType = nil } })
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } })
    }
}
