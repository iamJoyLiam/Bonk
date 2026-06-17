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
                diagnosis = aiService.currentExplanation ?? i18n.t(.couldNotDiagnose)
                aiService.currentExplanation = nil
            }
        }
    }
}
