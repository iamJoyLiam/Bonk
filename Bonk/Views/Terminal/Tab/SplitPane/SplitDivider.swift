//
//  SplitDivider.swift
//  Bonk
//
//  Draggable divider between split panes. The 1pt visual line is drawn as an
//  overlay on an 8pt invisible hit area so resizing with the mouse is easy.
//  The parent decides the divider's extent (width for a vertical divider,
//  height for a horizontal one) via explicit frames.
//

import SwiftUI

/// A draggable divider between split panes.
struct SplitDivider: View {
    enum Direction { case horizontal, vertical }

    let direction: Direction
    /// Reports the drag translation INCREMENT in points (horizontal split →
    /// x, vertical split → y). The container converts it into a fraction
    /// change. Increments (not cumulative translation) keep the math correct
    /// when the container re-renders mid-drag with a fresh fraction snapshot.
    var onResize: (CGFloat) -> Void = { _ in }
    /// Double-click resets this divider's two sides to equal shares.
    var onEqualize: () -> Void = {}

    @State private var lastOffset: CGFloat = 0
    @State private var isHovering = false
    @State private var lastClick = Date.distantPast

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .overlay {
                // A horizontal split (left-right) needs a VERTICAL line
                // spanning the full height; a vertical split (top-bottom)
                // needs a HORIZONTAL line spanning the full width.
                // The line only emphasizes while the pointer is on the gap.
                // It is not the drag state: a hover flag that survives a
                // re-render leaves a blue bar stuck in the gap.
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(isHovering ? 1 : 0.45))
                    .frame(
                        width: direction == .horizontal ? AppStyle.splitDividerThickness : nil,
                        height: direction == .vertical ? AppStyle.splitDividerThickness : nil
                    )
            }
            .onHover { inside in
                isHovering = inside
                let cursor: NSCursor = direction == .horizontal
                    ? .resizeLeftRight
                    : .resizeUpDown
                if inside {
                    cursor.push()
                } else {
                    NSCursor.pop()
                }
            }
            .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let current = direction == .horizontal
                        ? value.translation.width
                        : value.translation.height
                    // A click has no movement. Resizing it would shove the panes.
                    guard abs(current) >= 1 else { return }
                    let delta = current - lastOffset
                    lastOffset = current
                    onResize(delta)
                }
                .onEnded { value in
                    let moved = abs(direction == .horizontal ? value.translation.width : value.translation.height)
                    lastOffset = 0
                    isHovering = false
                    guard moved < 3 else { return }
                    let now = Date()
                    if now.timeIntervalSince(lastClick) < NSEvent.doubleClickInterval {
                        lastClick = .distantPast
                        onEqualize()
                    } else {
                        lastClick = now
                    }
                }
        )
    }
}
