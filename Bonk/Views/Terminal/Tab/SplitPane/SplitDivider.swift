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
    /// Reports the drag translation in points (horizontal split → x, vertical
    /// split → y). The container converts it into a fraction change.
    var onResize: (CGFloat) -> Void = { _ in }

    private var hitDimension: CGFloat { 8 }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .overlay {
                // A horizontal split (left-right) needs a VERTICAL line
                // spanning the full height; a vertical split (top-bottom)
                // needs a HORIZONTAL line spanning the full width.
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(
                        width: direction == .horizontal ? 1 : nil,
                        height: direction == .vertical ? 1 : nil
                    )
            }
            .onHover { inside in
                let cursor: NSCursor = direction == .horizontal
                    ? .resizeLeftRight
                    : .resizeUpDown
                if inside {
                    cursor.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        switch direction {
                        case .horizontal: onResize(value.translation.width)
                        case .vertical: onResize(value.translation.height)
                        }
                    }
            )
    }
}