//
//  TabLayoutView.swift
//  Bonk
//
//  Renders a tab's layout tree recursively.
//

import SwiftUI

struct TabLayoutView: View {
    @Environment(WorkspaceManager.self) private var workspace
    let tab: TerminalTab
    let sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let preferences: UserPreferences
    let cursorStyle: String
    let cursorBlink: Bool

    var body: some View {
        if workspace.isFocusMode, let activeID = tab.activePaneID, let pane = tab.layout.findPane(id: activeID) {
            HStack(spacing: 0) {
                // Focus side list — narrow, like JumpHost list
                VStack(spacing: 0) {
                    ForEach(tab.layout.root.allPaneIDs, id: \.self) { pid in
                        let isActive = pid == activeID
                        let title = tab.layout.findPane(id: pid)?.title ?? pid.uuidString.prefix(4).description
                        HStack(spacing: 6) {
                            Circle().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                            Text(title).font(.caption2).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { sessionManager.selectPane(pid) }
                        Divider()
                    }
                    Spacer()
                }
                .frame(width: 120)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                PaneTerminalView(
                    paneState: pane,
                    isActive: true,
                    tab: tab,
                    sessionManager: sessionManager,
                    colorScheme: colorScheme,
                    preferences: preferences,
                    cursorStyle: cursorStyle,
                    cursorBlink: cursorBlink
                )
            }
        } else {
            LayoutNodeView(
                node: tab.layout.root,
                activePaneID: tab.activePaneID ?? UUID(),
                tab: tab,
                sessionManager: sessionManager,
                colorScheme: colorScheme,
                preferences: preferences,
                cursorStyle: cursorStyle,
                cursorBlink: cursorBlink
            )
        }
    }
}
