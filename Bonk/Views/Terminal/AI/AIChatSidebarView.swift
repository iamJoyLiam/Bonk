import SwiftData
import SwiftUI

/// Full conversation-style AI chat panel for the right sidebar.
/// Supports Ask, Edit, and Agent modes.
struct AIChatSidebarView: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.modelContext) var modelContext
    let sshService: SSHNetworkService?
    @State var aiService = AIService.shared
    @State var providerStore = AIProviderStore()
    @State var conversationStore = AIConversationStore.shared
    @Query(sort: \AIConversationRecord.updatedAt, order: .reverse)
    var conversations: [AIConversationRecord]
    @State var currentConversation: AIConversationRecord?
    @State var inputText = ""
    @State var isProcessing = false
    @State var currentTask: Task<Void, Never>?
    @State var showHistory = false
    @State var selectedMode: AIMode = .ask
    @FocusState var isInputFocused: Bool

    @AppStorage("ai_enabled") var aiEnabled = false

    // Agent mode
    @State var agentSession: AgentSession?
    @State var agentMessages: [AgentMessage] = []

    @State var rotationAngle: Double = 0
    @State var fetchedModels: [String] = []
    @State var isFetchingModels = false
    @State var pendingDeleteConversation: UUID?

    private var aiColors: [Color] {
        AppStyle.aiRainbowColors
    }

    private var messages: [AIMessageRecord] {
        currentConversation?.messages ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if aiEnabled {
                header
                Divider()
                if selectedMode == .agent {
                    agentMessageList
                } else {
                    messageList
                }
                Divider()
                bottomBar
            } else {
                aiDisabledView
            }
        }
        .confirmationDialog(
            "Confirm Command",
            isPresented: .constant(agentSession?.pendingConfirmation != nil),
            presenting: agentSession?.pendingConfirmation
        ) { pending in
            Button("Execute", role: .destructive) {
                pending.continuation(true)
                agentSession?.pendingConfirmation = nil
            }
            Button("Cancel", role: .cancel) {
                pending.continuation(false)
                agentSession?.pendingConfirmation = nil
            }
        } message: { pending in
            Text("\(pending.riskLevel == .dangerous ? "⚠️ Dangerous" : "⚠️ Moderate") command:\n\(pending.command)")
        }
    }

    private var aiDisabledView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("AI Assistant")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Please enable AI in Settings to use this feature.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(i18n.t(.aiAssistant))
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Button { showHistory.toggle() } label: {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHistory) { historyPopover }

            Button { createNewConversation() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Regular Message List (Ask/Edit modes)

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty, !isProcessing {
                        emptyState
                    }
                    ForEach(messages) { msg in
                        bubble(msg)
                    }
                    if isProcessing {
                        if aiService.streamingResponse.isEmpty {
                            loadingBubble
                        } else {
                            streamingBubble(aiService.streamingResponse)
                        }
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

    // MARK: - Agent Message List

    private var agentMessageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if agentMessages.isEmpty, !isProcessing {
                        agentEmptyState
                    }
                    ForEach(agentMessages) { msg in
                        agentBubble(msg)
                    }
                    if isProcessing {
                        loadingBubble
                    }
                    Color.clear.frame(height: 1).id("agentBottom")
                }
                .padding(12)
            }
            .onChange(of: agentMessages.count) { _, _ in
                withAnimation(AppStyle.animationFast) { proxy.scrollTo("agentBottom", anchor: .bottom) }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isInputFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))

                TextField(selectedMode == .agent ? "Describe a task..." : i18n.t(.terminalAssistant), text: $inputText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($isInputFocused).onSubmit { submit() }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(.regularMaterial, in: Capsule())
            .background(
                Capsule()
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: aiColors),
                            center: .center,
                            angle: .degrees(rotationAngle)
                        ),
                        lineWidth: isInputFocused ? 3 : 0
                    )
                    .blur(radius: 6).opacity(isInputFocused ? 0.6 : 0)
            )

            HStack(spacing: 6) {
                modeMenu
                Spacer()
                if isProcessing {
                    Button {
                        cancelCurrentTask()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }
                modelMenu
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .onAppear {
            providerStore.setModelContext(modelContext)
            aiService.activeProvider = providerStore.activeProvider
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

    // MARK: - Actions

    private func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        if selectedMode == .agent {
            agentSession?.cancel()
        }
        aiService.currentExplanation = nil
        aiService.streamingResponse = ""
    }

    private func createNewConversation() {
        if selectedMode == .agent {
            agentMessages = []
            agentSession = nil
        } else {
            let conv = conversationStore.createConversation(context: modelContext)
            currentConversation = conv
            inputText = ""
            aiService.streamingResponse = ""
        }
    }

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if selectedMode == .agent {
            submitAgent(text: text)
        } else {
            submitChat(text: text)
        }
    }

    private func submitChat(text: String) {
        if currentConversation == nil {
            createNewConversation()
        }

        guard let conversation = currentConversation else { return }

        let modePrefix = switch selectedMode {
        case .ask: ""
        case .edit: "[Edit mode] Suggest a terminal command if relevant. "
        case .agent: "" // Agent uses separate flow
        }

        conversationStore.addMessage(to: conversation, role: .user, content: text, context: modelContext)
        isProcessing = true
        inputText = ""
        currentTask?.cancel()

        currentTask = Task {
            await aiService.chat(modePrefix + text, context: TerminalContext())
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isProcessing = false
                let response = aiService.currentExplanation ?? "No response."
                aiService.currentExplanation = nil
                aiService.streamingResponse = ""
                conversationStore.addMessage(
                    to: conversation,
                    role: .assistant,
                    content: response,
                    context: modelContext
                )
            }
        }
    }

    private func submitAgent(text: String) {
        // Initialize agent session if needed
        if agentSession == nil {
            guard let ssh = sshService else {
                agentMessages = [AgentMessage(
                    role: .system,
                    content: "No SSH connection. Please connect to a host first."
                )]
                return
            }
            agentSession = AgentSession(sshService: ssh, aiService: aiService)
        }

        guard let session = agentSession else { return }

        isProcessing = true
        inputText = ""
        currentTask?.cancel()

        currentTask = Task {
            await session.run(userInput: text)
            await MainActor.run {
                isProcessing = false
                agentMessages = session.messages
            }
        }
    }
}
