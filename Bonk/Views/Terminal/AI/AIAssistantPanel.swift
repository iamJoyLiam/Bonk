//
//  AIAssistantPanel.swift
//  Bonk
//
//  AI Assistant - query/response style with history.
//

import SwiftUI

/// AI Assistant panel - input stays, response appears below.
struct AIAssistantPanel: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.modelContext) private var modelContext
    @State private var aiService = AIService.shared
    @State private var conversationStore = AIConversationStore.shared
    @State private var inputText: String
    @State private var isProcessing = false
    @State private var showHistory = false
    @State private var currentTask: Task<Void, Never>?
    @FocusState private var isInputFocused: Bool

    let initialText: String
    let onPaste: (String) -> Void
    let onDismiss: () -> Void

    // Drag state
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// Rotation animation
    @State private var rotationAngle: Double = 0

    private var aiColors: [Color] {
        AppStyle.aiRainbowColors
    }

    /// Current conversation messages.
    private var messages: [AIMessage] {
        conversationStore.currentConversation?.messages ?? []
    }

    /// Last AI response.
    private var lastResponse: String? {
        messages.last(where: { $0.role == .assistant })?.content
    }

    init(initialText: String = "", onPaste: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.initialText = initialText
        _inputText = State(initialValue: initialText)
        self.onPaste = onPaste
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Input with Apple Intelligence glow
            HStack(spacing: 8) {
                // AI icon - click to show history
                Button {
                    showHistory.toggle()
                } label: {
                    Image(systemName: "apple.intelligence")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(
                            isInputFocused ?
                                AnyShapeStyle(Color.accentColor) :
                                AnyShapeStyle(Color.secondary)
                        )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showHistory) {
                    historyPopover
                }

                TextField(i18n.t(.terminalAssistant), text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isInputFocused)
                    .onSubmit { submit() }
                    .onExitCommand { dismiss() }

                if isProcessing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(i18n.t(.aiThinking))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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

            // AI Response - directly below input
            let streamingText = aiService.streamingResponse
            if isProcessing, !streamingText.isEmpty {
                // Show streaming response (plain text during stream)
                VStack(alignment: .leading, spacing: 6) {
                    Text(streamingText)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Color(nsColor: .controlColor))
                .clipShape(.rect(cornerRadius: 8))
            } else if let response = lastResponse {
                VStack(alignment: .leading, spacing: 6) {
                    markdownText(response)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Action buttons
                    HStack(spacing: 12) {
                        Button {
                            onPaste(response)
                        } label: {
                            Text(i18n.t(.aiPaste))
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(response, forType: .string)
                        } label: {
                            Text(i18n.t(.aiCopy))
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlColor))
                .clipShape(.rect(cornerRadius: 8))
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
            conversationStore.setModelContext(modelContext)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isInputFocused = true
            }
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                rotationAngle = 360
            }
            // Auto submit if initial text provided
            if !initialText.isEmpty {
                inputText = initialText
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    submit()
                }
            }
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    // MARK: - Markdown Rendering

    /// Render text with basic markdown support (code blocks, bold, italic).
    private func markdownText(_ text: String) -> some View {
        Text.markdown(text).font(.system(size: 13))
    }

    // MARK: - Submit

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Create conversation if needed
        if conversationStore.currentConversation == nil {
            conversationStore.newConversation()
        }

        // Add user message
        conversationStore.addMessage(role: .user, content: text)
        isProcessing = true

        // Keep input text - don't clear

        // Cancel any existing task
        currentTask?.cancel()

        currentTask = Task {
            await aiService.chat(text, context: TerminalContext())

            // Only add response if not cancelled
            guard !Task.isCancelled else { return }

            await MainActor.run {
                isProcessing = false
                let response = aiService.currentExplanation ?? "No response."
                aiService.currentExplanation = nil
                aiService.streamingResponse = ""

                // Add AI response only if task not cancelled
                conversationStore.addMessage(role: .assistant, content: response)
            }
        }
    }

    private func dismiss() {
        // Cancel any ongoing AI request
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false

        onDismiss()
        inputText = ""
        aiService.streamingResponse = ""
        aiService.currentExplanation = nil
    }

    // MARK: - History Popover

    private var historyPopover: some View {
        VStack(spacing: 0) {
            Text(i18n.t(.aiHistory))
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(conversationStore.conversations) { conversation in
                        Button {
                            conversationStore.selectConversation(conversation.id)
                            showHistory = false
                        } label: {
                            HStack {
                                Text(conversation.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                if conversationStore.currentConversation?.id == conversation.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .frame(width: 200)
    }
}

/// Error diagnosis floating bubble.
struct AIErrorDiagnosis: View {
    @EnvironmentObject var i18n: I18n
    @State private var aiService = AIService.shared
    @State private var isProcessing = false
    @State private var diagnosis: String?

    // Drag state
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    let selectedText: String
    let onApplyFix: ((String) -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Selected error text
            Text(selectedText)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlColor))
                .clipShape(.rect(cornerRadius: 6))

            if isProcessing {
                HStack {
                    ProgressView()
                        .controlSize(.mini)
                    Text(i18n.t(.aiAnalyzing))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let diagnosis {
                Text.markdown(diagnosis)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlColor))
                    .clipShape(.rect(cornerRadius: 6))

                HStack(spacing: 12) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnosis, forType: .string)
                    } label: {
                        Text(i18n.t(.aiCopy))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    if let onApplyFix {
                        Button {
                            onApplyFix(diagnosis)
                        } label: {
                            Text(i18n.t(.aiApply))
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: AppStyle.aiPanelWidth)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
        )
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
            diagnose()
        }
        .onExitCommand { onDismiss() }
    }

    private func diagnose() {
        isProcessing = true
        Task {
            let context = TerminalContext()
            await aiService.explainError(selectedText, context: context)
            await MainActor.run {
                isProcessing = false
                diagnosis = aiService.currentExplanation ?? "Could not diagnose."
                aiService.currentExplanation = nil
            }
        }
    }
}
