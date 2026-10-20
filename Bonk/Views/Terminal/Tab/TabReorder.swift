//
//  TabReorder.swift
//  Bonk
//
//  Where a dragged tab lands, and how far its neighbors slide to open that gap.
//  The dragged tab follows the pointer. Everyone else moves by one slot.
//

import CoreGraphics
import Foundation

enum TabReorder {
    /// Index the tab would occupy if dropped at `translation`.
    ///
    /// One slot is one tab width. The result stays inside the strip.
    static func destination(start: Int, translation: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 1, width > 0, start >= 0, start < count else { return start }
        let slots = Int((translation / width).rounded())
        return min(max(start + slots, 0), count - 1)
    }

    /// How many slots `index` shifts while `start` is held over `destination`.
    ///
    /// `-1` slides left, `+1` slides right. The dragged tab itself is `0`;
    /// its view follows the pointer separately.
    static func neighborShift(index: Int, start: Int, destination: Int) -> Int {
        if index == start { return 0 }
        if start < destination, index > start, index <= destination { return -1 }
        if start > destination, index < start, index >= destination { return 1 }
        return 0
    }
}

/// Which way a tab drag is going, once the pointer has moved far enough to tell.
enum TabDragIntent: Equatable {
    case pending
    case reorder
    case split
}

extension TabReorder {
    /// Horizontal movement locks in a reorder. A downward movement that is
    /// longer than it is wide locks in a split. A later change of direction
    /// does not switch, so a reorder cannot fall through into a split.
    static func intent(
        width: CGFloat,
        height: CGFloat,
        decided: TabDragIntent,
        reorderDistance: CGFloat,
        splitDistance: CGFloat
    ) -> TabDragIntent {
        if decided != .pending { return decided }
        let absWidth = abs(width)
        if height >= splitDistance, height > absWidth { return .split }
        if absWidth >= reorderDistance, absWidth >= abs(height) { return .reorder }
        return .pending
    }
}
