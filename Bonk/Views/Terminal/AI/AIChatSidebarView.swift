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
    @AppStorage("ai_agent_access_mode") var agentAccessModeRaw = "supervised"

    private var matchingSlashCommands: [AISlashCommand] {
        guard inputText.hasPrefix("/") && !inputText.contains(" ") else { return [] }
        let query = inputText.lowercased()
        if query == "/" { return AISlashCommand.allCases }
        return AISlashCommand.allCases.filter { $0.title.lowercased().hasPrefix(query) }
    }

    private var matchingMentions: [AIContextMention] {
        guard let lastToken = inputText.split(separator: " ", omittingEmptySubsequences: false).last,
              lastToken.hasPrefix("@") else { return [] }
        let query = String(lastToken).lowercased()
        if query == "@" { return AIContextMention.allCases }
        return AIContextMention.allCases.filter { $0.token.lowercased().hasPrefix(query) }
    }

    @State private var selectedPopupIndex = 0
    @State private var isPopupDismissed = false

    private var totalPopupMatchesCount: Int {
        matchingSlashCommands.count + matchingMentions.count
    }

    private var isPopupOpen: Bool {
        !isPopupDismissed && totalPopupMatchesCount > 0
    }

    @State private var rotationAngle: Double = 0
    @State var wasCancelled = false
    @State private var showModelPicker = false
    @State private var showModeMenu = false
    @State private var showAccessModePopover = false
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

    // MARK: - Regular Message List (Ask/Agent modes)

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                VStack(alignment: .leading, spacing: 14) {
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
            if isPopupOpen {
                SlashAndMentionPopup(
                    slashMatches: matchingSlashCommands,
                    mentionMatches: matchingMentions,
                    selectedIndex: selectedPopupIndex,
                    onSelectSlash: { cmd in handleSelectSlash(cmd) },
                    onSelectMention: { mention in handleSelectMention(mention) }
                )
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Leading: Apple Intelligence kaleidoscope icon button
                kaleidoscopeModeButton

                // Center: Text input field
                TextField(
                    selectedMode == .agent ? i18n.t(.describeTask) : i18n.t(.terminalAssistant),
                    text: $inputText,
                    axis: .vertical
                )
                .lineLimit(1 ... 5)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isInputFocused)
                .padding(.vertical, 4)
                .onKeyPress(.downArrow) {
                    guard isPopupOpen, totalPopupMatchesCount > 0 else { return .ignored }
                    selectedPopupIndex = (selectedPopupIndex + 1) % totalPopupMatchesCount
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard isPopupOpen, totalPopupMatchesCount > 0 else { return .ignored }
                    selectedPopupIndex = (selectedPopupIndex - 1 + totalPopupMatchesCount) % totalPopupMatchesCount
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard isPopupOpen, totalPopupMatchesCount > 0 else { return .ignored }
                    acceptSelectedPopupItem()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard isPopupOpen else { return .ignored }
                    isPopupDismissed = true
                    return .handled
                }
                .onKeyPress(.return) {
                    if isPopupOpen && !NSEvent.modifierFlags.contains(.shift) {
                        acceptSelectedPopupItem()
                        return .handled
                    }
                    if !NSEvent.modifierFlags.contains(.shift) {
                        submit()
                        return .handled
                    }
                    return .ignored
                }
                .onSubmit {
                    if !NSEvent.modifierFlags.contains(.shift) {
                        submit()
                    }
                }

                // Trailing: Permission button + Send/Stop button
                HStack(spacing: 6) {
                    if selectedMode == .agent {
                        agentAccessCircularButton
                    }
                    circularSendButton
                }
                .padding(.bottom, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: aiColors),
                            center: .center,
                            angle: .degrees(rotationAngle)
                        ),
                        lineWidth: (isInputFocused || engine.isProcessing) ? 3.5 : 0
                    )
                    .blur(radius: 6)
                    .opacity((isInputFocused || engine.isProcessing) ? 0.8 : 0)
            )
        }
        .padding(.horizontal, AppStyle.spacingML)
        .padding(.vertical, AppStyle.spacingS)
        .onChange(of: inputText) { _, _ in
            isPopupDismissed = false
            selectedPopupIndex = 0
        }
        .onAppear {
            providerStore.setModelContext(modelContext)
            engine.activeProvider = providerStore.activeProvider
            restoreLastConversation()
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                rotationAngle = 360
            }
        }
    }

    private func restoreLastConversation() {
        guard currentConversation == nil,
              let lastID = conversationStore.lastConversationID
        else { return }
        currentConversation = conversations.first(where: { $0.id == lastID })
    }

    // MARK: - Apple Intelligence Input Components

    private var kaleidoscopeModeButton: some View {
        Button {
            showModeMenu.toggle()
        } label: {
            Image(systemName: "apple.intelligence")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("切换模式：\(selectedMode == .agent ? i18n.t(.aiModeAgent) : i18n.t(.aiModeAsk))")
        .popover(isPresented: $showModeMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    selectedMode = .ask
                    showModeMenu = false
                } label: {
                    HStack {
                        Text(i18n.t(.aiModeAsk))
                            .font(.system(size: 12, weight: selectedMode == .ask ? .semibold : .regular))
                            .foregroundStyle(Color.primary)
                        Spacer()
                        if selectedMode == .ask {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    selectedMode = .agent
                    showModeMenu = false
                } label: {
                    HStack {
                        Text(i18n.t(.aiModeAgent))
                            .font(.system(size: 12, weight: selectedMode == .agent ? .semibold : .regular))
                            .foregroundStyle(Color.primary)
                        Spacer()
                        if selectedMode == .agent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(4)
            .frame(width: 120)
        }
    }

    private var currentAccessMode: AgentMessage.AccessMode {
        AgentMessage.AccessMode(rawValue: agentAccessModeRaw) ?? .supervised
    }

    private var agentAccessCircularButton: some View {
        Button {
            showAccessModePopover.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
                    .frame(width: 26, height: 26)

                Image(systemName: currentAccessMode.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(currentAccessMode == .fullAccess ? Color.accentColor : Color.secondary)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("执行权限：\(currentAccessMode.localizedName)")
        .popover(isPresented: $showAccessModePopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(AgentMessage.AccessMode.allCases) { mode in
                    Button {
                        agentAccessModeRaw = mode.rawValue
                        showAccessModePopover = false
                    } label: {
                        HStack {
                            Text(mode.localizedName)
                                .font(.system(size: 12, weight: currentAccessMode == mode ? .semibold : .regular))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if currentAccessMode == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .frame(width: 130)
        }
    }

    private var circularSendButton: some View {
        Group {
            if engine.isProcessing {
                Button {
                    cancelCurrentTask()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                            .frame(width: 26, height: 26)

                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.primary)
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(i18n.t(.cancel))
            } else {
                let canSend = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button {
                    submit()
                } label: {
                    ZStack {
                        Circle()
                            .fill(canSend ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.18))
                            .frame(width: 26, height: 26)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("发送 (↵)")
            }
        }
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

    private func submitPrompt(_ prompt: String) {
        if selectedMode == .agent {
            submitAgent(text: prompt)
        } else {
            submitChat(text: prompt)
        }
    }

    private func handleSelectSlash(_ cmd: AISlashCommand) {
        switch cmd {
        case .clear:
            inputText = ""
            createNewConversation()
        case .fix:
            inputText = ""
            submitPrompt(i18n.lang.hasPrefix("zh") ? "请检查并修复终端上一个执行失败的命令：\n@terminal" : "Please diagnose and fix the last failed terminal command:\n@terminal")
        case .explain:
            inputText = ""
            submitPrompt(i18n.lang.hasPrefix("zh") ? "请详细解释终端当前的输出内容与状态：\n@terminal" : "Please explain the current terminal output and status:\n@terminal")
        case .compact:
            inputText = ""
            submitPrompt(i18n.lang.hasPrefix("zh") ? "请总结并压缩我们迄今为止的对话关键点，精简上下文。" : "Please summarize the key points of our conversation to compact context.")
        case .help:
            inputText = ""
            let helpText = i18n.lang.hasPrefix("zh") ? """
            ### Bonk AI 智能助手快捷指南

            **快捷指令 (Slash Commands)**
            - `/clear` - 清空会话并重置对话
            - `/fix` - 诊断并修复终端最新执行报错
            - `/explain` - 解释终端屏幕当前输出
            - `/compact` - 总结对话历史压缩上下文
            - `/help` - 查看此帮助文档

            **上下文引用 (Context Mentions)**
            - `@terminal` - 注入终端当前屏幕内容
            - `@history` - 注入最近执行的命令记录
            - `@host` - 注入当前服务器环境信息
            - `@selection` - 注入终端选中的高亮文本

            **Agent 模式执行权限**
            - **完全访问**: 自动执行安全/查询与常规修改命令，高危命令弹窗确认
            - **逐步确认**: 每次变更操作均需审批确认
            - **只读模式**: 仅允许查询检测，阻断任何写操作
            """ : """
            ### Bonk AI Assistant Shortcuts

            **Slash Commands**
            - `/clear` - Clear and reset conversation
            - `/fix` - Diagnose and fix last failed terminal command
            - `/explain` - Explain current terminal output
            - `/compact` - Summarize and compact conversation context
            - `/help` - Show this help guide

            **Context Mentions**
            - `@terminal` - Attach recent terminal screen output
            - `@history` - Attach recent command history
            - `@host` - Attach connected host & server details
            - `@selection` - Attach selected terminal text

            **Agent Access Modes**
            - **Full Access**: Automatically runs safe & regular commands; confirms dangerous operations
            - **Supervised**: Manual confirmation required for mutating commands
            - **Read Only**: Inspection only; write commands blocked
            """
            if selectedMode == .agent {
                engine.agentMessages.append(AgentMessage(role: .assistant, content: helpText))
            } else {
                if currentConversation == nil { createNewConversation() }
                if let conversation = currentConversation {
                    conversationStore.addMessage(to: conversation, role: .assistant, content: helpText, context: modelContext)
                }
            }
        }
    }

    private func handleSelectMention(_ mention: AIContextMention) {
        var tokens = inputText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if let last = tokens.last, last.hasPrefix("@") {
            tokens.removeLast()
            tokens.append(mention.token)
            tokens.append("")
            inputText = tokens.joined(separator: " ")
        } else {
            inputText += (inputText.isEmpty || inputText.hasSuffix(" ") ? "" : " ") + mention.token + " "
        }
    }

    private func acceptSelectedPopupItem() {
        guard isPopupOpen, totalPopupMatchesCount > 0 else { return }
        let safeIndex = min(max(0, selectedPopupIndex), totalPopupMatchesCount - 1)
        if safeIndex < matchingSlashCommands.count {
            let cmd = matchingSlashCommands[safeIndex]
            handleSelectSlash(cmd)
        } else {
            let mentionIndex = safeIndex - matchingSlashCommands.count
            if mentionIndex < matchingMentions.count {
                let mention = matchingMentions[mentionIndex]
                handleSelectMention(mention)
            }
        }
        selectedPopupIndex = 0
    }

    private func submitChat(text: String) {
        if currentConversation == nil { createNewConversation() }
        guard let conversation = currentConversation else { return }

        conversationStore.addMessage(to: conversation, role: .user, content: text, context: modelContext)
        wasCancelled = false
        inputText = ""
        engine.isProcessing = true

        let expandedInput = ContextMentionResolver.expandMentions(
            in: text,
            terminalContext: terminalContext,
            tab: tab
        )

        currentTask?.cancel()
        currentTask = Task {
            let response = await engine.execute(
                input: expandedInput,
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
