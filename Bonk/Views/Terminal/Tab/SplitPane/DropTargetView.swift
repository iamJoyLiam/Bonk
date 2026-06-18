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
    @Environment(I18n.self) var i18n
    let onDrop: (UUID, DropPosition) -> Void
    @State private var isDragOver = false
    @State private var dropPosition: DropPosition = .right

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DropTargetNSView(
                    isDragOver: $isDragOver,
                    dropPosition: $dropPosition,
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
            Text(i18n.t(.dropToSplit))
                .font(.caption)
        }
        .foregroundStyle(Color.accentColor)

        let frame: (width: CGFloat?, height: CGFloat?) = switch dropPosition {
        case .left: (size.width / 2 - inset * 2, nil)
        case .right: (size.width / 2 - inset * 2, nil)
        case .top: (nil, size.height / 2 - inset * 2)
        case .bottom: (nil, size.height / 2 - inset * 2)
        }

        let position: CGPoint = switch dropPosition {
        case .left: CGPoint(x: size.width / 4, y: size.height / 2)
        case .right: CGPoint(x: size.width * 3 / 4, y: size.height / 2)
        case .top: CGPoint(x: size.width / 2, y: size.height / 4)
        case .bottom: CGPoint(x: size.width / 2, y: size.height * 3 / 4)
        }

        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, lineWidth: 3)
            .frame(width: frame.width, height: frame.height)
            .overlay { iconLabel }
            .position(position)
    }
}

// MARK: - AppKit NSView

private class DropTargetNSViewType: NSView {
    var onDrop: ((UUID, DropPosition) -> Void)?
    var isDragOver: Binding<Bool>?
    var dropPosition: Binding<DropPosition>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.init(UTType.bonkTabID.identifier)])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func calculateDropPosition(_ sender: NSDraggingInfo) -> DropPosition {
        let location = convert(sender.draggingLocation, from: nil)
        let w = bounds.width
        let h = bounds.height

        let distances: [(DropPosition, CGFloat)] = [
            (.left, location.x),
            (.right, w - location.x),
            (.top, h - location.y),
            (.bottom, location.y)
        ]

        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .right
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

// MARK: - NSViewRepresentable

private struct DropTargetNSView: NSViewRepresentable {
    @Binding var isDragOver: Bool
    @Binding var dropPosition: DropPosition
    let onDrop: (UUID, DropPosition) -> Void

    func makeNSView(context: Context) -> DropTargetNSViewType {
        let v = DropTargetNSViewType()
        v.onDrop = onDrop
        v.isDragOver = $isDragOver
        v.dropPosition = $dropPosition
        return v
    }

    func updateNSView(_ nsView: DropTargetNSViewType, context: Context) {
        nsView.onDrop = onDrop
        nsView.isDragOver = $isDragOver
        nsView.dropPosition = $dropPosition
    }
}
#endif
