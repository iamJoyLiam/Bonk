//
//  TabLayoutView.swift
//  Bonk
//
//  Renders a tab's layout tree recursively.
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
