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
            .onTapGesture {
                sessionManager.selectPane(paneState.id)
            }

        case let .horizontal(children, weights):
            GeometryReader { geometry in
                let available = Self.available(geometry.size.width, gaps: children.count - 1)
                HStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                        paneView(for: child)
                            .frame(
                                width: childSize(
                                    total: available,
                                    index: index,
                                    weights: weights
                                )
                            )
                            .frame(minWidth: AppStyle.size100)
                        if index < children.count - 1 {
                            SplitDivider(direction: .horizontal, onResize: { delta in
                                sessionManager.setSplitFraction(
                                    delta / max(available, 1),
                                    containerID: node.id,
                                    dividerIndex: index,
                                    in: tab
                                )
                            }, onEqualize: {
                                sessionManager.equalizeSplit(containerID: node.id, in: tab)
                            })
                            .frame(width: AppStyle.spacingML)
                            .frame(maxHeight: .infinity)
                        }
                    }
                }
            }
            .padding(isRoot ? AppStyle.spacingS : 0)
            .background(isRoot ? Color(nsColor: .windowBackgroundColor) : Color.clear)

        case let .vertical(children, weights):
            GeometryReader { geometry in
                let available = Self.available(geometry.size.height, gaps: children.count - 1)
                VStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                        paneView(for: child)
                            .frame(
                                height: childSize(
                                    total: available,
                                    index: index,
                                    weights: weights
                                )
                            )
                            .frame(minHeight: AppStyle.size100)
                        if index < children.count - 1 {
                            SplitDivider(direction: .vertical, onResize: { delta in
                                sessionManager.setSplitFraction(
                                    delta / max(available, 1),
                                    containerID: node.id,
                                    dividerIndex: index,
                                    in: tab
                                )
                            }, onEqualize: {
                                sessionManager.equalizeSplit(containerID: node.id, in: tab)
                            })
                            .frame(height: AppStyle.spacingML)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(isRoot ? AppStyle.spacingS : 0)
            .background(isRoot ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        }
    }

    private var isRoot: Bool { node.id == tab.layout.root.id }

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

    /// Room left for panes after the gaps between them.
    private static func available(_ total: CGFloat, gaps: Int) -> CGFloat {
        max(total - CGFloat(max(gaps, 0)) * AppStyle.spacingML, 0)
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
