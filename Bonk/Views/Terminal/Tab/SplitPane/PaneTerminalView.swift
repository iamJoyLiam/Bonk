//
//  PaneTerminalView.swift
//  Bonk
//
//  A single pane in the layout.
//

import SwiftUI

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
        .opacity(isActive ? 1.0 : 0.7)
        .contextMenu {
            Button { sessionManager.splitHorizontal() } label: {
                Label(i18n.t(.splitRight), systemImage: "rectangle.split.1x2")
            }
            Button { sessionManager.splitVertical() } label: {
                Label(i18n.t(.splitDown), systemImage: "rectangle.split.2x1")
            }
            Divider()
            Button(role: .destructive) {
                sessionManager.closePane(paneState.id, in: tab)
            } label: {
                Label(i18n.t(.closePane), systemImage: "xmark")
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
            Button {
                sessionManager.closePane(paneState.id, in: tab)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(i18n.t(.closePane))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }
}
