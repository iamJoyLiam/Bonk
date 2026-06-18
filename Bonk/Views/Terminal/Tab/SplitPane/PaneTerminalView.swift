//
//  PaneTerminalView.swift
//  Bonk
//
//  A single pane in the layout, wrapping TerminalContainerView.
//

import SwiftUI

/// A single pane in the layout, wrapping TerminalContainerView.
struct PaneTerminalView: View {
    @Environment(I18n.self) var i18n
    let paneState: PaneState
    let isActive: Bool
    let tab: TerminalTab
    let sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let preferences: UserPreferences
    let cursorStyle: String
    let cursorBlink: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Pane title bar (only show when there are multiple panes)
            if tab.layout.root.paneCount > 1 {
                paneTitleBar
            }

            PaneContainerBridge(
                paneState: paneState,
                tab: tab,
                colorScheme: colorScheme,
                fontSize: preferences.fontSize,
                fontFamily: preferences.fontFamily,
                lineHeight: preferences.lineHeight,
                scrollbackLines: preferences.scrollbackLines,
                cursorStyle: cursorStyle,
                cursorBlink: cursorBlink,
                copyOnSelect: preferences.copyOnSelect,
                isActive: isActive,
                onSend: { data in
                    Task {
                        do {
                            try await sessionManager.sendInput(data, to: tab.id, paneID: paneState.id)
                        } catch {
                            sessionManager.lastError = error.localizedDescription
                            sessionManager.showError = true
                        }
                    }
                },
                onResize: { cols, rows in
                    Task {
                        do {
                            try await sessionManager.resizePTY(cols: cols, rows: rows, tabID: tab.id, paneID: paneState.id)
                        } catch {}
                    }
                },
                onTitleChange: { _ in },
                onReconnect: { Task { await sessionManager.reconnectTab(tab.id) } }
            )
        }
        // Dim inactive panes
        .opacity(isActive ? 1.0 : 0.7)
        .contextMenu {
            Button {
                sessionManager.splitHorizontal()
            } label: {
                Label("Split Right", systemImage: "rectangle.split.1x2")
            }
            Button {
                sessionManager.splitVertical()
            } label: {
                Label("Split Down", systemImage: "rectangle.split.2x1")
            }
            Divider()
            Button(role: .destructive) {
                sessionManager.closePane(paneState.id, in: tab)
            } label: {
                Label("Close Pane", systemImage: "xmark")
            }
            .disabled(tab.layout.root.paneCount <= 1)
        }
    }

    private var paneTitleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tab.hostItem.host)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            // Close pane button
            Button {
                sessionManager.closePane(paneState.id, in: tab)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close this pane")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }
}
