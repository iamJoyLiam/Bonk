//
//  TerminalTabView+Helpers.swift
//  Bonk
//
//  Extracted from TerminalTabView.swift
//

import SwiftUI

extension TerminalTabView {
    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.quaternary)

            Text(i18n.t(.noTerminal))
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(i18n.t(.selectHost))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    func tabColor(_ state: SSHConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .disconnected: .red
        }
    }

    /// Copy selected text from terminal.
    func copySelectedText() {
        NotificationCenter.default.post(name: .requestTerminalSelection, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let selectedText = NSPasteboard.general.string(forType: .string), !selectedText.isEmpty {
                // Text already copied by SwiftTerm's clipboard handler
            }
        }
    }

    /// Paste text to terminal.
    func pasteToTerminal() {
        if let text = NSPasteboard.general.string(forType: .string) {
            let bytes = Array(text.utf8)
            if let activeTab = sessionManager.activeTab {
                Task {
                    try? await sessionManager.sendInput(bytes[...], to: activeTab.id)
                }
            }
        }
    }

    /// Select all text in terminal.
    func selectAllText() {
        NotificationCenter.default.post(name: .selectAllInTerminal, object: nil)
    }

    /// Clear terminal screen.
    func clearTerminal() {
        let clearBytes: [UInt8] = [12] // Form feed = clear screen
        if let activeTab = sessionManager.activeTab {
            Task {
                try? await sessionManager.sendInput(clearBytes[...], to: activeTab.id)
            }
        }
    }

    /// Focus the terminal view.
    func focusTerminal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .focusTerminal, object: nil)
        }
    }

    /// Request selected text from terminal and show AI panel.
    func requestSelectionAndShowAI() {
        guard aiEnabled else {
            showAIEnableAlert = true
            return
        }
        // Listen for selection response
        selectionObserver = NotificationCenter.default.addObserver(
            forName: .terminalSelectionResponse,
            object: nil,
            queue: .main
        ) { notification in
            if let selectedText = notification.object as? String, !selectedText.isEmpty {
                selectedTextForAI = selectedText
            } else {
                selectedTextForAI = ""
            }
            showAIChat = true
            // Remove observer after receiving response
            if let observer = selectionObserver {
                NotificationCenter.default.removeObserver(observer)
                selectionObserver = nil
            }
        }

        // Request selection from terminal
        NotificationCenter.default.post(name: .requestTerminalSelection, object: nil)

        // Fallback: if no response in 0.5 seconds, show AI chat
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if selectionObserver != nil {
                if let observer = selectionObserver {
                    NotificationCenter.default.removeObserver(observer)
                    selectionObserver = nil
                }
                selectedTextForAI = ""
                showAIChat = true
            }
        }
    }
}
