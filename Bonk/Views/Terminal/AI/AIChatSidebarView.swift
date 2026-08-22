import SwiftData
import SwiftUI

/// Full conversation-style AI chat panel for the right sidebar.
/// Supports Ask, Edit, and Agent modes.
struct AIChatSidebarView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) var modelContext
    @Bindable var sessionManager: SessionManager
    var tab: TerminalTab?
    var terminalContext: TerminalContext?
    var onPaste: ((String) -> Void)?
    var engine: AgentEngine {
        AgentEngine.shared
    }

    @State var providerStore = AIProviderStore.shared
    @State var conversationStore = AIConversationStore.shared
    @Query(sort: \AIConversationRecord.updatedAt, order: .reverse)
    var conversations: [AIConversationRecord]
    @State var currentConversation: AIConversationRecord?
    @State var inputText = ""
    @State var showHistory = false
    @State private var selectedMode: AIMode = .ask
    @FocusState var isInputFocused: Bool

    @AppStorage("ai_enabled") var aiEnabled = false
    @AppStorage("ai_allow_direct_connect") var allowDirectConnect = true

    @State private var rotationAngle: Double = 0
    @State var wasCancelled = false
    @State private var showModelPicker = false
    @State var pendingDeleteConversation: UUID?
    @State var currentTask: Task<Void, Never>?
    @State var targetStore = AgentTargetStore.shared
    @State var connectionService = AgentConnectionService.shared
    @State var pendingConnectHost: HostItem?
    @State var pendingSubmitText: String?
    @State var connectError: String?
    @Query(sort: \HostItem.sortOrder) var hosts: [HostItem]

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
                targetBar
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
        .alert(
            Text(String(format: i18n.t(.aiConfirmConnect), pendingConnectHost?.name ?? "")),
            isPresented: connectConfirmBinding
        ) {
            Button(i18n.t(.connect)) { confirmPendingConnect() }
            Button(i18n.t(.cancel), role: .cancel) { pendingConnectHost = nil }
        } message: {
            Text(pendingConnectHost?.host ?? "")
        }
        .alert(i18n.t(.connectionError), isPresented: errorBinding) {
            Button(i18n.t(.ok)) { connectError = nil }
        } message: {
            Text(connectError ?? "")
        }
    }

    private var aiDisabledView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: AppStyle.fontHero))
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
                .font(.system(size: AppStyle.fontRegular, weight: .semibold))

            Spacer()

            Button { showHistory.toggle() } label: {
                Image(systemName: "clock")
                    .font(.system(size: AppStyle.fontBody))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHistory) { historyPopover }

            Button { createNewConversation() } label: {
                Image(systemName: "plus")
                    .font(.system(size: AppStyle.fontBody))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingML)
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
                    Color.clear.frame(height: AppStyle.sizeHairline).id("bottom")
                }
                .padding(AppStyle.spacingL)
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
                    Color.clear.frame(height: AppStyle.sizeHairline).id("agentBottom")
                }
                .padding(AppStyle.spacingL)
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
                    .font(.system(size: AppStyle.fontBody, weight: .medium))
                    .foregroundStyle(isInputFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))

                TextField(selectedMode == .agent ? i18n.t(.describeTask) : i18n.t(.terminalAssistant), text: $inputText)
                    .textFieldStyle(.plain).font(.system(size: AppStyle.fontBody))
                    .focused($isInputFocused).onSubmit { submit() }

                if engine.isProcessing {
                    Button { cancelCurrentTask() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: AppStyle.fontBody))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, AppStyle.spacingL).frame(height: 34)
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
        .padding(.horizontal, AppStyle.spacingML).padding(.vertical, AppStyle.spacingM)
        .onAppear {
            providerStore.setModelContext(modelContext)
            engine.activeProvider = providerStore.activeProvider
            restoreLastConversation()
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) { rotationAngle = 360 }
        }
    }

    private func restoreLastConversation() {
        guard currentConversation == nil,
              let lastID = conversationStore.lastConversationID
        else { return }
        currentConversation = conversations.first(where: { $0.id == lastID })
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
                Image(systemName: selectedMode.icon).font(.system(size: AppStyle.fontSmall))
                Text(selectedMode.localizedName).font(.system(size: AppStyle.fontSmall))
                Image(systemName: "chevron.down").font(.system(size: AppStyle.fontTiny))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppStyle.spacingM).padding(.vertical, AppStyle.spacingXS)
            .background(Color(nsColor: .controlColor))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: - Actions

    private func cancelCurrentTask() {
        wasCancelled = true
        let partial = engine.streamingResponse
        currentTask?.cancel()
        currentTask = nil
        engine.cancel()

        if !partial.isEmpty, let conversation = currentConversation {
            conversationStore.addMessage(
                to: conversation, role: .assistant,
                content: partial, context: modelContext
            )
        }
    }

    func createNewConversation() {
        if selectedMode == .agent {
            engine.agentMessages = []
        } else {
            let conv = conversationStore.createConversation(context: modelContext)
            currentConversation = conv
            conversationStore.lastConversationID = conv.id
            inputText = ""
            engine.streamingResponse = ""
        }
    }

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !engine.isProcessing else { return }

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

        currentTask?.cancel()
        currentTask = Task {
            let response = await engine.execute(
                input: text,
                mode: selectedMode,
                context: terminalContext ?? TerminalContext()
            )

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

}
