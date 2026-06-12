//
//  SplitPaneContainer.swift
//  Bonk
//

import SwiftUI

/// Container for split pane layout with draggable dividers.
struct SplitPaneContainer<Content: View>: View {
    let direction: SplitDirection
    @Binding var ratio: Double
    let leading: Content
    let trailing: Content

    enum SplitDirection {
        case horizontal
        case vertical
    }

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            if direction == .horizontal {
                HStack(spacing: 0) {
                    leading
                        .frame(width: geo.size.width * ratio)

                    divider(
                        isVertical: true,
                        size: geo.size.width,
                        totalSize: geo.size.width
                    )

                    trailing
                }
            } else {
                VStack(spacing: 0) {
                    leading
                        .frame(height: geo.size.height * ratio)

                    divider(
                        isVertical: false,
                        size: geo.size.height,
                        totalSize: geo.size.height
                    )

                    trailing
                }
            }
        }
    }

    @ViewBuilder
    private func divider(isVertical: Bool, size: Double, totalSize: Double) -> some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(
                width: isVertical ? 4 : nil,
                height: isVertical ? nil : 4
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let translation = isVertical ? value.translation.width : value.translation.height
                        let newRatio = (size * ratio + translation) / totalSize
                        ratio = min(max(newRatio, 0.2), 0.8)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
