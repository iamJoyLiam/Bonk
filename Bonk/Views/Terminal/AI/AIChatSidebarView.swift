import SwiftUI

/// Full conversation-style AI chat panel for the right sidebar.
/// Has its own conversation state, independent from the floating AI panel.
struct AIChatSidebarView: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.modelContext) private var modelContext
    @State private var aiService = AIService.shared
    @State var conversationStore = AIConversationStore.shared
    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var currentTask: Task<Void, Never>?
    @State var showHistory = false
    @State private var selectedMode: AIMode = .ask
    @FocusState private var isInputFocused: Bool

    /// Sidebar has its own conversation, separate from floating panel
    @State var sidebarConversationID: UUID?

    @State private var rotationAngle: Double = 0
    @State var fetchedModels: [String] = []
    @State var isFetchingModels = false
    @State var pendingDeleteConversation: UUID?

    private var aiColors: [Color] {
        AppStyle.aiRainbowColors
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

    // MARK: - Messages

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
                    if isProcessing, !aiService.streamingResponse.isEmpty {
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

    // MARK: - Bottom Bar

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
            conversationStore.setModelContext(modelContext)
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

        let modePrefix = switch selectedMode {
        case .ask: ""
        case .edit: "[Edit mode] Suggest a terminal command if relevant. "
        case .agent: "[Agent mode] Provide a runnable terminal command. "
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
