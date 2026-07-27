//
//  LayoutNodeView.swift
//  Bonk
//
//  Recursive renderer for the layout tree.
//

import SwiftUI

/// Renders a LayoutNode tree recursively with split views.
struct LayoutNodeView: View {
    let node: LayoutNode
    let activePaneID: UUID
    let tab: TerminalTab
    let sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let preferences: UserPreferences
    let cursorStyle: String
    let cursorBlink: Bool

    var body: some View {
        switch node {
        case let .pane(paneState):
            PaneTerminalView(
                paneState: paneState,
                isActive: paneState.id == activePaneID,
                tab: tab,
                sessionManager: sessionManager,
                colorScheme: colorScheme,
                preferences: preferences,
                cursorStyle: cursorStyle,
                cursorBlink: cursorBlink
            )
            .transition(.asymmetric(
                insertion: .scale(scale: 0.95).combined(with: .opacity),
                removal: .opacity
            ))
            .onTapGesture {
                sessionManager.selectPane(paneState.id)
            }

        case let .horizontal(children):
            HStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    LayoutNodeView(
                        node: child,
                        activePaneID: activePaneID,
                        tab: tab,
                        sessionManager: sessionManager,
                        colorScheme: colorScheme,
                        preferences: preferences,
                        cursorStyle: cursorStyle,
                        cursorBlink: cursorBlink
                    )
                    .frame(minWidth: 100)
                    if index < children.count - 1 {
                        SplitDivider(direction: .horizontal)
                    }
                }
            }

        case let .vertical(children):
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    LayoutNodeView(
                        node: child,
                        activePaneID: activePaneID,
                        tab: tab,
                        sessionManager: sessionManager,
                        colorScheme: colorScheme,
                        preferences: preferences,
                        cursorStyle: cursorStyle,
                        cursorBlink: cursorBlink
                    )
                    .frame(minHeight: 100)
                    if index < children.count - 1 {
                        SplitDivider(direction: .vertical)
                    }
                }
            }
        }
    }
}
