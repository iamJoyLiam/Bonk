import SwiftUI

struct AIProviderDetailSheet: View {
    @EnvironmentObject var i18n: I18n
    let isNew: Bool
    let onSave: (AIProviderConfig) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var draft: AIProviderConfig
    @State private var apiKeyInput: String = ""
    @State private var showRemoveConfirmation = false

    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var fetchedModels: [String] = []
    @State private var isFetchingModels = false
    @State private var modelFetchError: String?
    @State private var modelFetchTask: Task<Void, Never>?

    @StateObject private var copilotService = CopilotService.shared

    enum TestResult: Equatable {
        case success
        case failure(String)
    }

    init(
        provider: AIProviderConfig,
        isNew: Bool,
        onSave: @escaping (AIProviderConfig) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self._draft = State(initialValue: provider)
        self._apiKeyInput = State(initialValue: provider.apiKey)
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
                modelSection
                advancedSection
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
                    Button(i18n.t(.save)) { cancelTasks(); onSave(draft) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .onAppear {
                if draft.type == .copilot { Task { await copilotService.start() } }
                if draft.type == .ollama { fetchModels() }
            }
            .onDisappear { cancelTasks() }
        }
        .frame(minWidth: 520, minHeight: 480)
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
        case .copilot: copilotAuthSection
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
                .disabled(isTesting || apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if case .success = testResult {
                Label(i18n.t(.connectionSuccessful), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            } else if case .failure(let msg) = testResult {
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red).font(.caption).lineLimit(3)
            }
        }
    }

    private var copilotAuthSection: some View {
        Section(i18n.t(.account)) {
            switch copilotService.authState {
            case .signedOut:
                HStack {
                    Text(i18n.t(.authenticationRequired)).foregroundStyle(.secondary)
                    Spacer()
                    Button(i18n.t(.signInGithub)) { Task { await copilotSignIn() } }
                        .disabled(copilotService.status != .running)
                }
            case .signingIn(let userCode, _, _):
                VStack(alignment: .leading, spacing: 8) {
                    Text(i18n.t(.enterCodeGithub))
                    Text(userCode).font(.system(.title2, design: .monospaced)).fontWeight(.bold).textSelection(.enabled)
                    Text(i18n.t(.codeCopied)).font(.caption).foregroundStyle(.secondary)
                    Text(i18n.t(.codeExpires)).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button(i18n.t(.completeSignIn)) { Task { await copilotCompleteSignIn() } }
                            .buttonStyle(.borderedProminent)
                        Button(i18n.t(.cancel), role: .cancel) { Task { await copilotService.signOut() } }
                    }
                }
            case .signedIn(let username):
                HStack {
                    Label(i18n.tr(.signedInAs, args: username), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button(i18n.t(.signOut)) { Task { await copilotService.signOut() } }
                }
            }

            if let error = copilotService.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            copilotStatusRow
        }
    }

    @ViewBuilder
    private var copilotStatusRow: some View {
        switch copilotService.status {
        case .stopped:
            Label(i18n.t(.serviceStopped), systemImage: "circle").foregroundStyle(.secondary).font(.caption)
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(i18n.t(.startingService)).font(.caption).foregroundStyle(.secondary)
            }
        case .running: EmptyView()
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption).lineLimit(2)
        }
    }

    // MARK: - Connection Section

    @ViewBuilder
    private var connectionSection: some View {
        if draft.type != .copilot {
            Section(i18n.t(.connection)) {
                if draft.type == .custom {
                    TextField(i18n.t(.name), text: $draft.name)
                }
                TextField(i18n.t(.endpoint), text: $draft.endpoint)
                    .onChange(of: draft.endpoint) { _, _ in testResult = nil; scheduleFetchModels() }
            }
        }
    }

    // MARK: - Model Section

    private var isCustomModel: Bool { !fetchedModels.contains(draft.model) }

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
            case .fetched(let id): draft.model = id
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
            if draft.type == .copilot {
                Toggle(i18n.t(.sendTelemetry), isOn: $draft.telemetryEnabled)
            }
        }
    }

    private var maxOutputTokensBinding: Binding<String> {
        Binding(get: { draft.maxOutputTokens.map(String.init) ?? "" }, set: { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { draft.maxOutputTokens = nil }
            else if let v = Int(trimmed), v > 0 { draft.maxOutputTokens = v }
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

    // MARK: - Networking

    private func cancelTasks() {
        modelFetchTask?.cancel()
        modelFetchTask = nil
    }

    private func scheduleFetchModels() {
        modelFetchTask?.cancel()
        modelFetchTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            fetchModels()
        }
    }

    private func fetchModels() {
        guard draft.type.needsAPIKey || draft.type == .ollama else { return }
        if draft.type.needsAPIKey && draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fetchedModels = []; modelFetchError = nil; return
        }
        guard let url = AIProviderNetworking.modelsURL(endpoint: draft.endpoint, type: draft.type, apiKey: draft.apiKey) else { return }

        isFetchingModels = true; modelFetchError = nil
        modelFetchTask?.cancel()
        modelFetchTask = Task {
            do {
                let request = AIProviderNetworking.makeRequest(url: url, apiKey: draft.apiKey, type: draft.type)
                let models = try await AIProviderNetworking.fetchModels(request: request, type: draft.type)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    fetchedModels = models
                    if draft.model.isEmpty, let first = models.first { draft.model = first }
                    isFetchingModels = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { modelFetchError = error.localizedDescription; isFetchingModels = false }
            }
        }
    }

    private func testProvider() {
        let trimmed = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { testResult = .failure(i18n.t(.apiKeyRequired)); return }
        guard let url = AIProviderNetworking.modelsURL(endpoint: draft.endpoint, type: draft.type, apiKey: draft.apiKey) else {
            testResult = .failure(i18n.t(.connectionTestFailed)); return
        }

        isTesting = true; testResult = nil
        Task {
            do {
                let request = AIProviderNetworking.makeRequest(url: url, apiKey: draft.apiKey, type: draft.type)
                let ok = try await AIProviderNetworking.testConnection(request: request)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTesting = false
                    testResult = ok ? .success : .failure(i18n.t(.connectionTestFailed))
                    if ok { fetchModels() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { isTesting = false; testResult = .failure(error.localizedDescription) }
            }
        }
    }

    // MARK: - Copilot Actions

    private func copilotSignIn() async {
        do { try await copilotService.signIn() }
        catch { copilotService.errorMessage = error.localizedDescription }
    }

    private func copilotCompleteSignIn() async {
        do { try await copilotService.completeSignIn() }
        catch { copilotService.errorMessage = error.localizedDescription }
    }
}
