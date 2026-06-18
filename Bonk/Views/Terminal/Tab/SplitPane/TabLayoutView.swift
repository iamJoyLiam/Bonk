//
//  TabLayoutView.swift
//  Bonk
//
//  Renders a tab's layout tree recursively with drag-to-split support.
//

import SwiftUI

struct TabLayoutView: View {
    let tab: TerminalTab
    let sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let preferences: UserPreferences
    let cursorStyle: String
    let cursorBlink: Bool

    var body: some View {
        ZStack {
            LayoutNodeView(
                node: tab.layout.root,
                activePaneID: tab.activePaneID,
                tab: tab,
                sessionManager: sessionManager,
                colorScheme: colorScheme,
                preferences: preferences,
                cursorStyle: cursorStyle,
                cursorBlink: cursorBlink
            )

            DropTargetView { sourceTabID, position in
                sessionManager.addPaneFromTab(sourceTabID, to: tab.id, position: position)
            }
        }
    }
}
