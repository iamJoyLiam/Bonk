import SwiftUI

/// Full conversation-style AI chat panel for the right sidebar.
/// Has its own conversation state, independent from the floating AI panel.
struct AIChatSidebarView: View {
    @EnvironmentObject var i18n: I18n
    @State private var aiService = AIService.shared
    @State private var conversationStore = AIConversationStore.shared
    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var currentTask: Task<Void, Never>?
    @State private var showHistory = false
    @State private var selectedMode: AIMode = .ask
    @FocusState private var isInputFocused: Bool

    // Sidebar has its own conversation, separate from floating panel
    @State private var sidebarConversationID: UUID?

    @State private var rotationAngle: Double = 0

    private var aiColors: [Color] { AppStyle.aiRainbowColors }

    enum AIMode: String, CaseIterable {
        case ask = "Ask"
        case edit = "Edit"
        case agent = "Agent"

        var icon: String {
            switch self {
            case .ask: return "questionmark.circle"
            case .edit: return "pencil.circle"
            case .agent: return "bolt.circle"
            }
        }

        var description: String {
            switch self {
            case .ask: return "Answer questions only"
            case .edit: return "Can suggest terminal commands"
            case .agent: return "Can execute commands directly"
            }
        }
    }

    /// Current sidebar conversation (independent from floating panel).
    private var conversation: AIConversation? {
        if let id = sidebarConversationID {
            return conversationStore.conversations.first(where: { $0.id == id })
        }
        return nil
    }

    private var messages: [AIMessage] {
        conversation?.messages ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            bottomBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(i18n.t(.aiAssistant))
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            // History
            Button { showHistory.toggle() } label: {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHistory) { historyPopover }

            // New conversation
            Button { newConversation() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - History

    @State private var pendingDeleteConversation: UUID?

    private var historyPopover: some View {
        VStack(spacing: 0) {
            if conversationStore.conversations.isEmpty {
                Text(i18n.t(.aiNoHistory))
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(conversationStore.conversations) { c in
                            HStack(spacing: 8) {
                                Button {
                                    sidebarConversationID = c.id
                                    showHistory = false
                                } label: {
                                    HStack {
                                        Text(c.title).font(.system(size: 12)).lineLimit(1)
                                        Spacer()
                                        if sidebarConversationID == c.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                // Delete button
                                Button {
                                    pendingDeleteConversation = c.id
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .frame(width: 220)
        .alert(i18n.t(.aiDeleteConversation), isPresented: Binding(
            get: { pendingDeleteConversation != nil },
            set: { if !$0 { pendingDeleteConversation = nil } }
        )) {
            Button(i18n.t(.delete), role: .destructive) {
                if let id = pendingDeleteConversation {
                    conversationStore.deleteConversation(id)
                    if sidebarConversationID == id { sidebarConversationID = nil }
                }
                pendingDeleteConversation = nil
            }
            Button(i18n.t(.cancel), role: .cancel) { pendingDeleteConversation = nil }
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && !isProcessing {
                        emptyState
                    }
                    ForEach(messages) { msg in
                        bubble(msg)
                    }
                    if isProcessing && !aiService.streamingResponse.isEmpty {
                        streamingBubble(aiService.streamingResponse)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: aiService.streamingResponse) { _, _ in
                withAnimation(AppStyle.animationFast) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(AppStyle.animationFast) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(i18n.t(.terminalAssistant))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func bubble(_ msg: AIMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.role == .assistant { avatar("sparkles") }
            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
                Text.markdown(msg.content).font(.system(size: 13)).textSelection(.enabled)
            }
            .padding(10)
            .background(msg.role == .user ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlColor))
            .clipShape(.rect(cornerRadius: 10))
            if msg.role == .user { avatar("person.fill") }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func streamingBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            avatar("sparkles")
            Text(text).font(.system(size: 13))
                .padding(10)
                .background(Color(nsColor: .controlColor))
                .clipShape(.rect(cornerRadius: 10))
        }
    }

    private func avatar(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background(Color(nsColor: .controlColor))
            .clipShape(Circle())
    }

    // MARK: - Bottom Bar

    @State private var fetchedModels: [String] = []
    @State private var isFetchingModels = false

    private var bottomBar: some View {
        VStack(spacing: 6) {
            // Input
            HStack(spacing: 8) {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isInputFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))

                TextField(i18n.t(.terminalAssistant), text: $inputText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($isInputFocused).onSubmit { submit() }

                if isProcessing { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(.regularMaterial, in: Capsule())
            .background(
                Capsule()
                    .stroke(AngularGradient(gradient: Gradient(colors: aiColors), center: .center, angle: .degrees(rotationAngle)), lineWidth: isInputFocused ? 3 : 0)
                    .blur(radius: 6).opacity(isInputFocused ? 0.6 : 0)
            )

            // Mode + Model
            HStack(spacing: 6) {
                // Mode dropdown
                modeMenu

                Spacer()

                // Model dropdown
                modelMenu
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .onAppear {
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) { rotationAngle = 360 }
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(AIMode.allCases, id: \.self) { mode in
                Button { selectedMode = mode } label: {
                    Label(mode.rawValue, systemImage: mode.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedMode.icon).font(.system(size: 11))
                Text(selectedMode.rawValue).font(.system(size: 11))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(nsColor: .controlColor))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var modelMenu: some View {
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

    private var activeProvider: AIProviderConfig? { AIProviderStore.activeProvider }
    private var allProviders: [AIProviderConfig] { AIProviderStore.allProviders }

    // MARK: - Model Operations

    private func fetchModels() {
        guard let provider = activeProvider,
              let url = AIProviderNetworking.modelsURL(endpoint: provider.endpoint, type: provider.type, apiKey: provider.apiKey) else { return }
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

    private func switchToProvider(_ provider: AIProviderConfig) {
        UserDefaults.standard.set(provider.id.uuidString, forKey: "ai_active_provider_id")
        fetchedModels = []
        fetchModels()
    }

    private func applyModel(_ model: String) {
        guard var provider = activeProvider else { return }
        provider.model = model.trimmingCharacters(in: .whitespaces)
        AIProviderStore.updateProvider(provider)
    }

    // MARK: - Actions

    private func newConversation() {
        let conv = AIConversation()
        conversationStore.conversations.insert(conv, at: 0)
        sidebarConversationID = conv.id
        inputText = ""
        aiService.streamingResponse = ""
    }

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Ensure sidebar has its own conversation
        if sidebarConversationID == nil || conversation == nil {
            newConversation()
        }

        // Add message to sidebar conversation
        if let conv = conversation {
            var updated = conv
            updated.messages.append(AIMessage(role: .user, content: text))
            updated.title = conv.title == "New Chat" ? String(text.prefix(30)) : conv.title
            updated.updatedAt = Date()
            if let idx = conversationStore.conversations.firstIndex(where: { $0.id == conv.id }) {
                conversationStore.conversations[idx] = updated
            }
        }

        isProcessing = true
        inputText = ""
        currentTask?.cancel()

        let modePrefix: String
        switch selectedMode {
        case .ask: modePrefix = ""
        case .edit: modePrefix = "[Edit mode] Suggest a terminal command if relevant. "
        case .agent: modePrefix = "[Agent mode] Provide a runnable terminal command. "
        }

        currentTask = Task {
            await aiService.chat(modePrefix + text, context: TerminalContext())
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isProcessing = false
                let response = aiService.currentExplanation ?? "No response."
                aiService.currentExplanation = nil
                aiService.streamingResponse = ""

                if let conv = conversation {
                    var updated = conv
                    updated.messages.append(AIMessage(role: .assistant, content: response))
                    updated.updatedAt = Date()
                    if let idx = conversationStore.conversations.firstIndex(where: { $0.id == conv.id }) {
                        conversationStore.conversations[idx] = updated
                    }
                }
            }
        }
    }
}
