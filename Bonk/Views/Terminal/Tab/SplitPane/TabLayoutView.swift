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
        .padding(AppStyle.spacingM)
    }
}

/// The surface the terminal cards sit on.
///
/// On macOS 26 this is Liquid Glass, so the gap around a card — one pane or
/// several — shows the window rather than another slab of gray. Earlier
/// systems use the same material the glass effect replaced.
struct TerminalDeskBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle()
                .fill(.regularMaterial)
        }
    }
}
