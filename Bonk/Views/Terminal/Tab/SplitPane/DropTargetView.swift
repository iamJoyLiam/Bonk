//
//  DropTargetView.swift
//  Bonk
//
//  AppKit drop target with region indicator
//

import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

/// Drop position enum
enum DropPosition {
    case left, right, top, bottom
}

struct DropTargetView: View {
    let onDrop: (UUID, DropPosition) -> Void
    @State private var isDragOver = false
    @State private var dropPosition: DropPosition = .right

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DropTargetNSView(
                    isDragOver: $isDragOver,
                    dropPosition: $dropPosition,
                    frameSize: geometry.size,
                    onDrop: onDrop
                )

                if isDragOver {
                    dropIndicator(in: geometry.size)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.15), value: isDragOver)
                }
            }
        }
    }

    @ViewBuilder
    private func dropIndicator(in size: CGSize) -> some View {
        let inset: CGFloat = 4
        let iconLabel = VStack(spacing: 8) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 24))
            Text("Drop to split")
                .font(.caption)
        }
        .foregroundStyle(Color.accentColor)

        switch dropPosition {
        case .left:
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 3)
                .frame(width: size.width / 2 - inset * 2)
                .overlay { iconLabel }
                .position(x: size.width / 4, y: size.height / 2)
        case .right:
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 3)
                .frame(width: size.width / 2 - inset * 2)
                .overlay { iconLabel }
                .position(x: size.width * 3 / 4, y: size.height / 2)
        case .top:
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 3)
                .frame(height: size.height / 2 - inset * 2)
                .overlay { iconLabel }
                .position(x: size.width / 2, y: size.height / 4)
        case .bottom:
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 3)
                .frame(height: size.height / 2 - inset * 2)
                .overlay { iconLabel }
                .position(x: size.width / 2, y: size.height * 3 / 4)
        }
    }
}

private class DropTargetNSViewType: NSView {
    var onDrop: ((UUID, DropPosition) -> Void)?
    var isDragOver: Binding<Bool>?
    var dropPosition: Binding<DropPosition>?
    var frameSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.init(UTType.bonkTabID.identifier)])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 根据鼠标位置计算最近的边
    private func calculateDropPosition(_ sender: NSDraggingInfo) -> DropPosition {
        let location = convert(sender.draggingLocation, from: nil)
        let w = bounds.width
        let h = bounds.height

        let distLeft = location.x
        let distRight = w - location.x
        let distTop = h - location.y
        let distBottom = location.y

        let minDist = min(distLeft, distRight, distTop, distBottom)

        switch minDist {
        case distLeft: return .left
        case distRight: return .right
        case distTop: return .top
        default: return .bottom
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.init(UTType.bonkTabID.identifier)) == true {
            isDragOver?.wrappedValue = true
            dropPosition?.wrappedValue = calculateDropPosition(sender)
            return .copy
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropPosition?.wrappedValue = calculateDropPosition(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragOver?.wrappedValue = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let position = calculateDropPosition(sender)
        isDragOver?.wrappedValue = false

        guard let data = sender.draggingPasteboard.data(forType: .init(UTType.bonkTabID.identifier)),
              let payload = try? JSONDecoder().decode(TabDragPayload.self, from: data) else {
            return false
        }

        onDrop?(payload.id, position)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDragOver?.wrappedValue = false
    }
}

private struct DropTargetNSView: NSViewRepresentable {
    @Binding var isDragOver: Bool
    @Binding var dropPosition: DropPosition
    let frameSize: CGSize
    let onDrop: (UUID, DropPosition) -> Void

    func makeNSView(context: Context) -> DropTargetNSViewType {
        let v = DropTargetNSViewType()
        v.onDrop = onDrop
        v.isDragOver = $isDragOver
        v.dropPosition = $dropPosition
        v.frameSize = frameSize
        return v
    }

    func updateNSView(_ nsView: DropTargetNSViewType, context: Context) {
        nsView.onDrop = onDrop
        nsView.isDragOver = $isDragOver
        nsView.dropPosition = $dropPosition
        nsView.frameSize = frameSize
    }
}
#endif
