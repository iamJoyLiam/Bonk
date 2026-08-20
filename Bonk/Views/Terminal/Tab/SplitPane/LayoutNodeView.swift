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

        case let .horizontal(children, fraction):
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                        paneView(for: child)
                            .frame(
                                width: childSize(
                                    total: geometry.size.width,
                                    index: index,
                                    count: children.count,
                                    fraction: fraction
                                )
                            )
                            .frame(minWidth: 100)
                        if index < children.count - 1 {
                            SplitDivider(direction: .horizontal) { delta in
                                sessionManager.setSplitFraction(
                                    fraction + delta / max(geometry.size.width, 1),
                                    containerID: node.id,
                                    in: tab
                                )
                            }
                            .frame(width: 8)
                            .frame(maxHeight: .infinity)
                        }
                    }
                }
            }

        case let .vertical(children, fraction):
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                        paneView(for: child)
                            .frame(
                                height: childSize(
                                    total: geometry.size.height,
                                    index: index,
                                    count: children.count,
                                    fraction: fraction
                                )
                            )
                            .frame(minHeight: 100)
                        if index < children.count - 1 {
                            SplitDivider(direction: .vertical) { delta in
                                sessionManager.setSplitFraction(
                                    fraction + delta / max(geometry.size.height, 1),
                                    containerID: node.id,
                                    in: tab
                                )
                            }
                            .frame(height: 8)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    /// The child view for a layout node.
    @ViewBuilder
    private func paneView(for child: LayoutNode) -> some View {
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
    }

    /// Size for the child at `index`: the first child takes `fraction` of the
    /// total, the remaining children share the rest evenly.
    private func childSize(
        total: CGFloat,
        index: Int,
        count: Int,
        fraction: CGFloat
    ) -> CGFloat {
        guard count > 1 else { return total }
        if index == 0 { return total * fraction }
        return total * (1 - fraction) / CGFloat(count - 1)
    }
}