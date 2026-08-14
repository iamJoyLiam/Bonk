//
//  TerminalAIPanel.swift
//  Bonk
//
//  Quick AI input overlay (Cmd+Option+K). Same engine and conversation store
//  as the sidebar chat — one source of truth, real terminal context attached.
//

import SwiftData
import SwiftUI

/// Floating AI assistant panel over the terminal.
/// - Input capsule with Ask/Edit modes.
/// - Streaming markdown response below.
/// - Actions: copy / paste / run in terminal.
struct TerminalAIPanel: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @State private var engine = AgentEngine.shared
    @State private var providerStore = AIProviderStore.shared
    @State private var conversationStore = AIConversationStore.shared
    @Query(sort: \AIConversationRecord.updatedAt, order: .reverse)
    private var conversations: [AIConversationRecord]
    @State private var currentConversation: AIConversationRecord?
    @State private var inputText: String
    @State private var selectedMode: AIMode = .ask
    @State private var currentTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool
    @Query private var allPreferences: [UserPreferences]

    // Drag state
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var rotationAngle: Double = 0

    let initialText: String
    let terminalContext: TerminalContext
    let onPaste: (String) -> Void
    let onRun: (String) -> Void
    let onDismiss: () -> Void

    private var aiColors: [Color] {
        AppStyle.aiRainbowColors
    }

    private var messages: [AIMessageRecord] {
        (currentConversation?.messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    /// Last completed assistant response.
    private var lastResponse: String? {
        messages.last(where: { $0.role == .assistant })?.content
    }

    init(
        initialText: String = "",
        terminalContext: TerminalContext = TerminalContext(),
        onPaste: @escaping (String) -> Void,
        onRun: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initialText = initialText
        self.terminalContext = terminalContext
        _inputText = State(initialValue: initialText)
        self.onPaste = onPaste
        self.onRun = onRun
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputBar

            if engine.isProcessing {
                streamingBubble
            } else if let response = lastResponse, !response.isEmpty {
                responseBubble(response)
            } else if let error = engine.lastError {
                errorBubble(error)
            }
        }
        .frame(width: AppStyle.aiPanelWidth)
        .offset(offset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    lastOffset = offset
                }
        )
        .onAppear {
            providerStore.setModelContext(modelContext)
            engine.activeProvider = providerStore.activeProvider
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                isInputFocused = true
            }
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                rotationAngle = 360
            }
            // Direct-submit when invoked on a selection (setting-gated).
            if !initialText.isEmpty, preferences.aiDirectSubmit {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    submit()
                }
            }
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onExitCommand { dismiss() }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    isInputFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary)
                )

            TextField(i18n.t(.terminalAssistant), text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isInputFocused)
                .onSubmit { submit() }

            if engine.isProcessing {
                Button {
                    cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                modeMenu
            }
        }
        .padding(.horizontal, 16)
        .frame(width: AppStyle.aiPanelWidth, height: 44)
        .background(.regularMaterial, in: Capsule())
        .background(
            Capsule()
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: aiColors),
                        center: .center,
                        angle: .degrees(rotationAngle)
                    ),
                    lineWidth: isInputFocused ? 6 : 0
                )
                .blur(radius: 8)
                .opacity(isInputFocused ? 0.8 : 0)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                .opacity(isInputFocused ? 1 : 0)
        )
    }

    private var modeMenu: some View {
        Menu {
            ForEach(AIMode.allCases.filter { $0 != .agent }, id: \.self) { mode in
                Button { selectedMode = mode } label: {
                    Label(mode.localizedName, systemImage: mode.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedMode.icon)
                    .font(.system(size: 11))
                Text(selectedMode.localizedName)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Response

    private var streamingBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if engine.streamingResponse.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(i18n.t(.aiThinking))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    MarkdownTextView(
                        content: engine.streamingResponse,
                        onRun: { code in onRun(code) }
                    )
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func responseBubble(_ response: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                MarkdownTextView(
                    content: response,
                    onRun: { code in onRun(code) }
                )
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)

            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(response, forType: .string)
                } label: {
                    Text(i18n.t(.aiCopy))
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    onPaste(response)
                    dismiss()
                } label: {
                    Text(i18n.t(.aiPaste))
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Button {
                    onRun(response)
                    dismiss()
                } label: {
                    Text(i18n.t(.aiRun))
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func errorBubble(_ error: String) -> some View {
        Text(error)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlColor))
            .clipShape(.rect(cornerRadius: 10))
    }

    // MARK: - Actions

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if currentConversation == nil {
            currentConversation = conversationStore.createConversation(context: modelContext)
        }
        guard let conversation = currentConversation else { return }

        conversationStore.addMessage(
            to: conversation, role: .user, content: text, context: modelContext
        )
        inputText = ""
        engine.lastError = nil

        currentTask?.cancel()
        currentTask = Task {
            let response = await engine.execute(input: text, mode: selectedMode, context: terminalContext)
            guard !Task.isCancelled else { return }
            if let response, !response.isEmpty {
                conversationStore.addMessage(
                    to: conversation, role: .assistant, content: response, context: modelContext
                )
            }
        }
    }

    private func cancel() {
        currentTask?.cancel()
        currentTask = nil
        engine.cancel()
    }

    private func dismiss() {
        currentTask?.cancel()
        currentTask = nil
        engine.cancel()
        inputText = ""
        onDismiss()
    }

    private var preferences: UserPreferences {
        allPreferences.first ?? UserPreferences()
    }
}
