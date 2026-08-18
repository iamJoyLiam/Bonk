import SwiftUI

struct AIProviderDetailSheet: View {
    @Environment(I18n.self) var i18n
    let isNew: Bool
    let onSave: (AIProviderConfig) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State var draft: AIProviderConfig
    @State var apiKeyInput: String = ""
    @State var showRemoveConfirmation = false

    @State var isTesting = false
    @State var testResult: TestResult?
    @State var fetchedModels: [String] = []
    @State var isFetchingModels = false
    @State var modelFetchError: String?
    @State var modelFetchTask: Task<Void, Never>?
    @State var showModelRequiredAlert = false
    @State var headerFields: [HeaderField] = []

    enum TestResult: Equatable {
        case success
        case failure(String)
    }

    struct HeaderField: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    init(
        provider: AIProviderConfig,
        isNew: Bool,
        onSave: @escaping (AIProviderConfig) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: provider)
        _apiKeyInput = State(initialValue: provider.apiKey)
        // Seed fetchedModels with current model so Picker doesn't default to "Other"
        _fetchedModels = State(initialValue: provider.model.isEmpty ? [] : [provider.model])
        _headerFields = State(initialValue: provider.extraHeaders.map {
            HeaderField(key: $0.key, value: $0.value)
        })
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                authSection
                connectionSection
                if draft.type.allowsProtocolSelection { protocolSection }
                modelSection
                advancedSection
                if draft.type == .custom { extraHeadersSection }
                if onDelete != nil, !isNew { deleteSection }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(isNew ? i18n.tr(.addType, args: draft.type.displayName) : draft.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t(.cancel)) { cancelTasks(); onCancel() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.t(.save)) {
                        syncHeadersToDraft()
                        if draft.type == .custom, draft.model.trimmingCharacters(in: .whitespaces).isEmpty {
                            showModelRequiredAlert = true
                        } else {
                            cancelTasks(); onSave(draft)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .onAppear {
                if draft.type == .ollama || (draft.type.needsAPIKey && !draft.apiKey.isEmpty) {
                    fetchModels()
                }
            }
            .onChange(of: headerFields) { _, _ in
                syncHeadersToDraft()
            }
            .onDisappear { cancelTasks() }
        }
        .frame(minWidth: 520, minHeight: 480)
        .alert(i18n.t(.modelRequired), isPresented: $showModelRequiredAlert) {
            Button(i18n.t(.ok), role: .cancel) {}
        } message: {
            Text(i18n.t(.modelRequiredHint))
        }
        .confirmationDialog(i18n.t(.removeProviderQ), isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
            Button(i18n.t(.removeProvider), role: .destructive) { onDelete?() }
            Button(i18n.t(.cancel), role: .cancel) {}
        } message: {
            Text(i18n.t(.providerDeletedHint))
        }
    }

    // MARK: - Auth Section

    @ViewBuilder
    private var authSection: some View {
        switch draft.type {
        case .ollama: EmptyView()
        default: apiKeyAuthSection
        }
    }

    private var apiKeyAuthSection: some View {
        Section(i18n.t(.authentication)) {
            SecureField(i18n.t(.apiKey), text: $apiKeyInput)
                .onChange(of: apiKeyInput) { _, newValue in
                    draft.apiKey = newValue
                    testResult = nil
                    scheduleFetchModels()
                }

            HStack {
                Spacer()
                Button { testProvider() } label: {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text(i18n.t(.testConnection))
                    }
                }
                .disabled(
                    isTesting
                        || (draft.type != .custom
                            && apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
            }

            if case .success = testResult {
                Label(i18n.t(.connectionSuccessful), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            } else if case let .failure(msg) = testResult {
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red).font(.caption).lineLimit(3)
            }
        }
    }

    // MARK: - Connection Section

    @ViewBuilder
    private var connectionSection: some View {
        Section(i18n.t(.connection)) {
            if draft.type == .custom {
                TextField(i18n.t(.name), text: $draft.name)
            }
            TextField(i18n.t(.endpoint), text: $draft.endpoint)
                .onChange(of: draft.endpoint) { _, _ in testResult = nil; scheduleFetchModels() }
        }
    }

    // MARK: - Protocol Section

    private var protocolSection: some View {
        Section(i18n.t(.apiProtocol)) {
            Picker(i18n.t(.apiProtocol), selection: $draft.protocolType) {
                ForEach(AIProviderProtocol.allCases) { protocolType in
                    Text(protocolType.displayName).tag(protocolType)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: draft.protocolType) { _, _ in
                testResult = nil
            }

            Text(i18n.t(.apiProtocolHint))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Model Section

    private var isCustomModel: Bool {
        !fetchedModels.contains(draft.model)
    }

    private var modelSection: some View {
        Section(i18n.t(.model)) {
            Picker(i18n.t(.model), selection: modelSelectionBinding) {
                ForEach(fetchedModels, id: \.self) { Text($0).tag(ModelSelection.fetched($0)) }
                Text(i18n.t(.other)).tag(ModelSelection.custom)
            }
            .pickerStyle(.menu)

            if isCustomModel {
                TextField(i18n.t(.modelId), text: $draft.model)
            }

            if isFetchingModels {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(i18n.t(.fetchingModels)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = modelFetchError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Spacer()
                    Button(i18n.t(.reload)) { fetchModels() }.buttonStyle(.borderless).controlSize(.small)
                }
            }
        }
    }

    private enum ModelSelection: Hashable { case fetched(String), custom }

    private var modelSelectionBinding: Binding<ModelSelection> {
        Binding(get: {
            fetchedModels.contains(draft.model) ? .fetched(draft.model) : .custom
        }, set: { newValue in
            switch newValue {
            case let .fetched(id): draft.model = id
            case .custom: if fetchedModels.contains(draft.model) { draft.model = "" }
            }
        })
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        Section(i18n.t(.advanced)) {
            HStack {
                Text(i18n.t(.maxOutputTokens))
                Spacer()
                TextField("", text: maxOutputTokensBinding)
                    .frame(width: 100).multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - Extra Headers (custom OpenAI-compatible providers)

    private var extraHeadersSection: some View {
        Section(i18n.t(.extraHeaders)) {
            ForEach($headerFields) { $field in
                HStack(spacing: 8) {
                    TextField(i18n.t(.headerName), text: $field.key)
                        .frame(width: 140)
                    TextField(i18n.t(.headerValue), text: $field.value)
                    Button(role: .destructive) {
                        removeHeader(field.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                headerFields.append(HeaderField(key: "", value: ""))
            } label: {
                Label(i18n.t(.addHeader), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    private func removeHeader(_ id: UUID) {
        headerFields.removeAll { $0.id == id }
    }

    func syncHeadersToDraft() {
        let pairs = headerFields.compactMap { field -> (String, String)? in
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return (key, field.value)
        }
        draft.extraHeaders = Dictionary(uniqueKeysWithValues: pairs)
    }

    private var maxOutputTokensBinding: Binding<String> {
        Binding(get: { draft.maxOutputTokens.map(String.init) ?? "" }, set: { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                draft.maxOutputTokens = nil
            } else if let tokenCount = Int(trimmed), tokenCount > 0 {
                draft.maxOutputTokens = tokenCount
            }
        })
    }

    // MARK: - Delete Section

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) { showRemoveConfirmation = true } label: {
                Label(i18n.t(.removeProvider), systemImage: "trash").frame(maxWidth: .infinity)
            }
        }
    }
}
