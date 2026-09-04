import SwiftData
import SwiftUI

struct AISettingsView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @AppStorage("ai_enabled") private var aiEnabled = false
    @AppStorage("ai_inline_suggestions") private var inlineSuggestionsEnabled = false
    @AppStorage("ai_inline_candidate_popup") private var candidatePopupEnabled = false
    @AppStorage("ai_include_terminal") private var includeTerminalOutput = true
    @AppStorage("ai_include_history") private var includeCommandHistory = true
    @AppStorage("ai_include_env") private var includeEnvironmentInfo = false
    @AppStorage("ai_connection_policy") private var defaultConnectionPolicyRaw = "askEachTime"
    @AppStorage("ai_allow_direct_connect") private var allowDirectConnect = true
    @AppStorage("ai_agent_access_mode") private var agentAccessModeRaw = "supervised"
    @AppStorage("ai_agent_max_iterations") private var agentMaxIterations = 25
    @AppStorage("ai_inline_provider_id") private var inlineProviderID = ""

    @State private var store = AIProviderStore.shared

    @State private var editingProviderID: UUID?
    @State private var addingProviderType: AIProviderType?
    @State private var pendingDeleteID: UUID?

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

                // Agent
                agentSection

                // Context
                contextSection

                // Privacy
                privacySection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            store.setModelContext(modelContext)
        }
        .sheet(isPresented: editingSheetBinding) {
            if let id = editingProviderID,
               let provider = store.providers.first(where: { $0.id == id })
            {
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
                .onChange(of: store.activeProviderID) { _, newValue in store.setActive(newValue) }
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
                .padding(.vertical, AppStyle.spacingS)
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
            .frame(width: AppStyle.iconXL)

            Image(systemName: provider.type.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: AppStyle.iconDisplay)

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
        .padding(.vertical, AppStyle.spacingXXS)
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
        [.claude, .openAI, .openRouter, .openCode, .deepSeek, .qwen, .kimi, .gemini, .ollama]
    }

    // MARK: - Inline Suggestions

    private var inlineSuggestionsSection: some View {
        Section {
            Toggle(i18n.t(.enableInlineSuggestions), isOn: $inlineSuggestionsEnabled)
                .disabled(store.activeProviderID == nil)
                .help(store.activeProviderID != nil ? "" : i18n.t(.configureProviderHint))
            Picker(i18n.t(.aiInlineModel), selection: $inlineProviderID) {
                Text(i18n.t(.aiFollowMainProvider)).tag("")
                ForEach(store.providers) { provider in
                    Text(provider.displayName).tag(provider.id.uuidString)
                }
            }
            .disabled(!inlineSuggestionsEnabled)
            Toggle(i18n.t(.aiCandidatePopup), isOn: $candidatePopupEnabled)
                .disabled(!inlineSuggestionsEnabled)
        } header: {
            Text(i18n.t(.inlineSuggestions))
        } footer: {
            Text("\(i18n.t(.inlineSuggestionsFooter))\n\(i18n.t(.aiInlineModelDesc))\n\(i18n.t(.aiCandidatePopupDesc))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Agent

    private var agentSection: some View {
        Section {
            Picker("执行权限模式", selection: $agentAccessModeRaw) {
                ForEach(AgentMessage.AccessMode.allCases) { mode in
                    Label(mode.localizedName, systemImage: mode.icon).tag(mode.rawValue)
                }
            }
            Stepper("最大执行轮次: \(agentMaxIterations) 轮", value: $agentMaxIterations, in: 5...50, step: 5)
            Toggle(i18n.t(.aiAllowDirectConnect), isOn: $allowDirectConnect)
        } header: {
            Text(i18n.t(.agentMode))
        } footer: {
            Text("完全访问：自主执行常规命令，高危命令仍需确认；逐步确认：修改命令需逐一确认；只读模式：只允许只读检查。\n\(i18n.t(.aiDirectConnectDesc))")
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
