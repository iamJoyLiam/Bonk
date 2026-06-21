//
//  PaneTerminalView.swift
//  Bonk
//
//  A single pane in the layout, supporting independent and linked modes.
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

    @State private var focusManager = FocusManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if tab.layout.root.paneCount > 1 {
                paneTitleBar
            }

            paneContent
        }
        .opacity(isActive ? 1.0 : 0.6)
        .overlay {
            if tab.layout.root.paneCount > 1 {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
            }
        }
        .onTapGesture {
            focusManager.focus(paneState.id)
            tab.activePaneID = paneState.id
        }
        .contextMenu {
            contextMenuContent
        }
    }

    // MARK: - Pane Content

    @ViewBuilder
    private var paneContent: some View {
        switch paneState.sessionMode {
        case .independent:
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
                onSend: { data in sendInput(data) },
                onResize: { cols, rows in resizePTY(cols: cols, rows: rows) },
                onTitleChange: { _ in },
                onReconnect: { Task { await sessionManager.reconnectTab(tab.id) } }
            )

        case .linked(let sourceID):
            // Linked mode: show indicator that this pane is linked
            if let sourcePane = tab.layout.findPane(id: sourceID) {
                PaneContainerBridge(
                    paneState: sourcePane,
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
                    onSend: { data in sendInput(data) },
                    onResize: { cols, rows in resizePTY(cols: cols, rows: rows) },
                    onTitleChange: { _ in },
                    onReconnect: { Task { await sessionManager.reconnectTab(tab.id) } }
                )
                .overlay(alignment: .bottomTrailing) {
                    Label("Linked", systemImage: "link")
                        .font(.caption2)
                        .padding(4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            }
        }
    }

    // MARK: - Title Bar

    private var paneTitleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: paneTitleIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tab.hostItem.host)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            // Broadcast indicator
            if tab.isBroadcastEnabled {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

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

    private var paneTitleIcon: String {
        switch paneState.sessionMode {
        case .independent: "terminal"
        case .linked: "link"
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button { sessionManager.splitHorizontal() } label: {
            Label(i18n.t(.splitRight), systemImage: "rectangle.split.1x2")
        }
        Button { sessionManager.splitVertical() } label: {
            Label(i18n.t(.splitDown), systemImage: "rectangle.split.2x1")
        }

        Divider()

        // Link/Unlink options
        if case .independent = paneState.sessionMode {
            Menu("Link to Pane") {
                ForEach(tab.layout.root.allPaneIDs.filter { $0 != paneState.id }, id: \.self) { otherID in
                    Button {
                        sessionManager.linkPanes(sourceID: otherID, targetID: paneState.id, in: tab)
                    } label: {
                        Text("Pane \(otherID.uuidString.prefix(4))")
                    }
                }
            }
        } else {
            Button {
                sessionManager.unlinkPane(paneState.id, in: tab)
            } label: {
                Label("Unlink Pane", systemImage: "link.badge.xmark")
            }
        }

        Divider()

        Button(role: .destructive) {
            sessionManager.closePane(paneState.id, in: tab)
        } label: {
            Label(i18n.t(.closePane), systemImage: "xmark")
        }
        .disabled(tab.layout.root.paneCount <= 1)
    }

    // MARK: - Helpers

    private func sendInput(_ data: ArraySlice<UInt8>) {
        Task {
            do {
                try await sessionManager.sendInput(data, to: tab.id, paneID: paneState.id)
            } catch {
                sessionManager.lastError = error.localizedDescription
                sessionManager.showError = true
            }
        }
    }

    private func resizePTY(cols: Int, rows: Int) {
        Task {
            do {
                try await sessionManager.resizePTY(cols: cols, rows: rows, tabID: tab.id, paneID: paneState.id)
            } catch {}
        }
    }
}
