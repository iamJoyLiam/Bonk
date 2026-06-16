import SwiftData
import SwiftUI

/// Full conversation-style AI chat panel for the right sidebar.
/// Supports Ask, Edit, and Agent modes.
struct AIChatSidebarView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) var modelContext
    let sshService: SSHNetworkService?
    var onPaste: ((String) -> Void)?
    var engine: AgentEngine {
        AgentEngine.shared
    }

    @State var providerStore = AIProviderStore.shared
    @State var conversationStore = AIConversationStore.shared
    @Query(sort: \AIConversationRecord.updatedAt, order: .reverse)
    var conversations: [AIConversationRecord]
    @State var currentConversation: AIConversationRecord?
    @State private var inputText = ""
    @State var showHistory = false
    @State private var selectedMode: AIMode = .ask
    @FocusState var isInputFocused: Bool

    @AppStorage("ai_enabled") var aiEnabled = false

    @State private var rotationAngle: Double = 0
    @State private var wasCancelled = false
    @State private var showModelPicker = false
    @State var pendingDeleteConversation: UUID?

    private var aiColors: [Color] {
        AppStyle.aiRainbowColors
    }

    private var messages: [AIMessageRecord] {
        (currentConversation?.messages ?? []).sorted { $0.timestamp < $1.timestamp }
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
                if let plan = engine.currentPlan {
                    agentPlanApprovalView(plan)
                }
                if let pending = engine.pendingConfirmation {
                    agentConfirmationBanner(pending)
                }
                Divider()
                bottomBar
            } else {
                aiDisabledView
            }
        }
    }

    private var aiDisabledView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(i18n.t(.aiAssistant))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(i18n.t(.aiNotEnabled))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            SettingsLink {
                Label(i18n.t(.goToSettings), systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
            .onTapGesture {
                UserDefaults.standard.set("ai", forKey: "settings_selected_tab")
            }
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
                    if messages.isEmpty, !engine.isProcessing {
                        emptyState
                    }
                    ForEach(messages) { msg in
                        bubble(msg)
                    }
                    if engine.isProcessing {
                        if engine.streamingResponse.isEmpty {
                            loadingBubble
                        } else {
                            streamingBubble(engine.streamingResponse)
                        }
                    }
                    if wasCancelled, !engine.isProcessing {
                        stoppedIndicator
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: engine.streamingResponse) { _, _ in
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
                    if engine.agentMessages.isEmpty, !engine.isProcessing {
                        agentEmptyState
                    }
                    ForEach(engine.agentMessages) { msg in
                        agentBubble(msg)
                    }
                    if engine.isProcessing {
                        loadingBubble
                    }
                    Color.clear.frame(height: 1).id("agentBottom")
                }
                .padding(12)
            }
            .onChange(of: engine.agentMessages.count) { _, _ in
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

                TextField(selectedMode == .agent ? i18n.t(.describeTask) : i18n.t(.terminalAssistant), text: $inputText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($isInputFocused).onSubmit { submit() }

                if engine.isProcessing {
                    Button { cancelCurrentTask() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
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
                modelMenu
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .onAppear {
            providerStore.setModelContext(modelContext)
            engine.activeProvider = providerStore.activeProvider
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) { rotationAngle = 360 }
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(AIMode.allCases, id: \.self) { mode in
                Button { selectedMode = mode } label: {
                    Label(mode.localizedName, systemImage: mode.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedMode.icon).font(.system(size: 11))
                Text(selectedMode.localizedName).font(.system(size: 11))
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
        wasCancelled = true
        let partial = engine.streamingResponse
        engine.cancel()

        if !partial.isEmpty, let conversation = currentConversation {
            conversationStore.addMessage(
                to: conversation, role: .assistant,
                content: partial, context: modelContext
            )
        }
    }

    private func createNewConversation() {
        if selectedMode == .agent {
            engine.agentMessages = []
        } else {
            let conv = conversationStore.createConversation(context: modelContext)
            currentConversation = conv
            inputText = ""
            engine.streamingResponse = ""
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
        if currentConversation == nil { createNewConversation() }
        guard let conversation = currentConversation else { return }

        conversationStore.addMessage(to: conversation, role: .user, content: text, context: modelContext)
        wasCancelled = false
        inputText = ""
        engine.isProcessing = true

        Task {
            let response = await engine.execute(input: text, mode: selectedMode)

            if let response, !response.isEmpty, !wasCancelled {
                conversationStore.addMessage(
                    to: conversation, role: .assistant,
                    content: response, context: modelContext
                )
            } else if !wasCancelled {
                let error = engine.lastError ?? "No response from AI. Check your API key and model settings."
                conversationStore.addMessage(
                    to: conversation, role: .assistant,
                    content: "⚠️ \(error)", context: modelContext
                )
            }
            engine.isProcessing = false
        }
    }

    private func submitAgent(text: String) {
        guard let ssh = sshService else {
            engine.agentMessages = [AgentMessage(
                role: .system, content: i18n.t(.noSSHConnectionAgent)
            )]
            return
        }

        if currentConversation == nil { createNewConversation() }
        let conversation = currentConversation

        inputText = ""
        wasCancelled = false
        engine.isProcessing = true

        Task {
            await engine.runAgent(
                input: text, sshService: ssh,
                conversation: conversation, context: modelContext
            )
            engine.isProcessing = false
        }
    }
}
