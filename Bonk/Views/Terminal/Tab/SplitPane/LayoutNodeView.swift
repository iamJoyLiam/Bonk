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

        case let .horizontal(children, weights):
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                        paneView(for: child)
                            .frame(
                                width: childSize(
                                    total: geometry.size.width,
                                    index: index,
                                    weights: weights
                                )
                            )
                            .frame(minWidth: AppStyle.size100)
                        if index < children.count - 1 {
                            SplitDivider(direction: .horizontal) { delta in
                                sessionManager.setSplitFraction(
                                    delta / max(geometry.size.width, 1),
                                    containerID: node.id,
                                    dividerIndex: index,
                                    in: tab
                                )
                            }
                            .frame(width: AppStyle.statusDotMedium)
                            .frame(maxHeight: .infinity)
                        }
                    }
                }
            }

        case let .vertical(children, weights):
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                        paneView(for: child)
                            .frame(
                                height: childSize(
                                    total: geometry.size.height,
                                    index: index,
                                    weights: weights
                                )
                            )
                            .frame(minHeight: 100)
                        if index < children.count - 1 {
                            SplitDivider(direction: .vertical) { delta in
                                sessionManager.setSplitFraction(
                                    delta / max(geometry.size.height, 1),
                                    containerID: node.id,
                                    dividerIndex: index,
                                    in: tab
                                )
                            }
                            .frame(height: AppStyle.statusDotMedium)
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

    /// Size for the child at `index`: its share of the total is
    /// `weight / sum(weights)` — dragging one divider only moves the two
    /// adjacent children.
    private func childSize(
        total: CGFloat,
        index: Int,
        weights: [CGFloat]
    ) -> CGFloat {
        guard index < weights.count else { return total }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return total / CGFloat(max(weights.count, 1)) }
        return total * weights[index] / sum
    }
}