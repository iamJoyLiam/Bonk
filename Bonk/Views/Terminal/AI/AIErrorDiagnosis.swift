//
//  AIErrorDiagnosis.swift
//  Bonk
//
//  Error diagnosis floating bubble for terminal errors.
//

import SwiftUI

/// Error diagnosis floating bubble.
struct AIErrorDiagnosis: View {
    @Environment(I18n.self) var i18n
    @State private var engine = AgentEngine.shared
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
            Text(selectedText)
                .font(.system(size: AppStyle.fontSmall, design: .monospaced))
                .lineLimit(3)
                .padding(AppStyle.spacingM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlColor))
                .clipShape(.rect(cornerRadius: AppStyle.cornerRadiusSmall))

            if isProcessing {
                HStack {
                    ProgressView()
                        .controlSize(.mini)
                    Text(i18n.t(.aiAnalyzing))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let diagnosis {
                MarkdownTextView(content: diagnosis)
                    .font(.system(size: AppStyle.fontBody))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppStyle.spacingM)
                    .background(Color(nsColor: .controlColor))
                    .clipShape(.rect(cornerRadius: AppStyle.cornerRadiusSmall))

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
        .padding(AppStyle.spacingXLPlus)
        .frame(width: AppStyle.aiPanelWidth)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusLarge)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(AppStyle.opacityBackgroundStrong), radius: 12, x: 0, y: 4)
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
            let systemPrompt = """
            You are a terminal error diagnoser embedded in an SSH client.
            Explain the error briefly and suggest a fix. \
            Reply in plain text, no markdown.
            Match the user's language.
            """
            let response = await engine.execute(
                input: selectedText,
                mode: .ask,
                context: context,
                systemPromptOverride: systemPrompt
            )
            await MainActor.run {
                isProcessing = false
                diagnosis = response ?? engine.lastError ?? i18n.t(.couldNotDiagnose)
            }
        }
    }
}
