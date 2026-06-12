//
//  SplitPane.swift
//  Bonk
//

import SwiftUI

/// Represents a split pane layout — either a single terminal or two sub-panes.
indirect enum SplitPane {
    case single(TerminalPane)
    case horizontal(left: SplitPane, right: SplitPane, ratio: Double)
    case vertical(top: SplitPane, bottom: SplitPane, ratio: Double)

    /// Terminal pane with its own connection state.
    struct TerminalPane: Identifiable {
        let id: UUID
        var hostID: UUID?

        init(id: UUID = UUID(), hostID: UUID? = nil) {
            self.id = id
            self.hostID = hostID
        }
    }

    /// Find the active pane ID in this tree.
    var activePaneID: UUID? {
        switch self {
        case let .single(pane): pane.id
        case let .horizontal(left, _, _): left.activePaneID
        case let .vertical(top, _, _): top.activePaneID
        }
    }

    /// Count total panes.
    var paneCount: Int {
        switch self {
        case .single: 1
        case let .horizontal(left, right, _): left.paneCount + right.paneCount
        case let .vertical(top, bottom, _): top.paneCount + bottom.paneCount
        }
    }

    /// Split the active pane horizontally (side by side).
    mutating func splitHorizontal(activeID: UUID) {
        switch self {
        case let .single(pane) where pane.id == activeID:
            self = .horizontal(left: .single(pane), right: .single(TerminalPane()), ratio: 0.5)
        case let .horizontal(left, right, ratio):
            var newLeft = left
            var newRight = right
            newLeft.splitHorizontal(activeID: activeID)
            newRight.splitHorizontal(activeID: activeID)
            self = .horizontal(left: newLeft, right: newRight, ratio: ratio)
        case let .vertical(top, bottom, ratio):
            var newTop = top
            var newBottom = bottom
            newTop.splitHorizontal(activeID: activeID)
            newBottom.splitHorizontal(activeID: activeID)
            self = .vertical(top: newTop, bottom: newBottom, ratio: ratio)
        default:
            break
        }
    }

    /// Split the active pane vertically (top/bottom).
    mutating func splitVertical(activeID: UUID) {
        switch self {
        case let .single(pane) where pane.id == activeID:
            self = .vertical(top: .single(pane), bottom: .single(TerminalPane()), ratio: 0.5)
        case let .horizontal(left, right, ratio):
            var newLeft = left
            var newRight = right
            newLeft.splitVertical(activeID: activeID)
            newRight.splitVertical(activeID: activeID)
            self = .horizontal(left: newLeft, right: newRight, ratio: ratio)
        case let .vertical(top, bottom, ratio):
            var newTop = top
            var newBottom = bottom
            newTop.splitVertical(activeID: activeID)
            newBottom.splitVertical(activeID: activeID)
            self = .vertical(top: newTop, bottom: newBottom, ratio: ratio)
        default:
            break
        }
    }

    /// Close a pane by ID. Returns false if this pane should be removed.
    mutating func closePane(id: UUID) -> Bool {
        switch self {
        case let .single(pane):
            return pane.id != id

        case let .horizontal(left, right, ratio):
            var newLeft = left
            var newRight = right
            let leftAlive = newLeft.closePane(id: id)
            let rightAlive = newRight.closePane(id: id)

            if leftAlive && rightAlive {
                self = .horizontal(left: newLeft, right: newRight, ratio: ratio)
                return true
            } else if leftAlive {
                self = newLeft
                return true
            } else if rightAlive {
                self = newRight
                return true
            } else {
                return false
            }

        case let .vertical(top, bottom, ratio):
            var newTop = top
            var newBottom = bottom
            let topAlive = newTop.closePane(id: id)
            let bottomAlive = newBottom.closePane(id: id)

            if topAlive && bottomAlive {
                self = .vertical(top: newTop, bottom: newBottom, ratio: ratio)
                return true
            } else if topAlive {
                self = newTop
                return true
            } else if bottomAlive {
                self = newBottom
                return true
            } else {
                return false
            }
        }
    }
}

extension SplitPane: Equatable {
    static func == (lhs: SplitPane, rhs: SplitPane) -> Bool {
        switch (lhs, rhs) {
        case let (.single(a), .single(b)): a.id == b.id
        case let (.horizontal(l1, r1, ratio1), .horizontal(l2, r2, ratio2)):
            l1 == l2 && r1 == r2 && ratio1 == ratio2
        case let (.vertical(t1, b1, ratio1), .vertical(t2, b2, ratio2)):
            t1 == t2 && b1 == b2 && ratio1 == ratio2
        default: false
        }
    }
}
