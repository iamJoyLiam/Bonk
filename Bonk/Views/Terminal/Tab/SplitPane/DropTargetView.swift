//
//  DropTargetView.swift
//  Bonk
//
//  AppKit drop target - forwards events to terminal view directly.
//

import SwiftUI

/// Drop position enum
enum DropPosition {
    case left, right, top, bottom

    var isHorizontal: Bool {
        self == .left || self == .right
    }

    var isVertical: Bool {
        self == .top || self == .bottom
    }
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
                    frameSize: geometry.size,
                    onDrop: onDrop
                )

                if isDragOver {
                    dropIndicator(in: geometry.size)
                        .allowsHitTesting(false)
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
    var frameSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Return self so drag events work
    override func hitTest(_ point: NSPoint) -> NSView? {
        return self
    }

    // Find the terminal view in sibling views and forward events
    private func findTerminalView() -> NSView? {
        guard let superview else { return nil }
        for subview in superview.subviews {
            if subview !== self && subview is NSView {
                // Check if this view or its subviews contain SwiftTerm
                if findSwiftTerm(in: subview) != nil {
                    return subview
                }
            }
        }
        return nil
    }

    private func findSwiftTerm(in view: NSView) -> NSView? {
        let typeName = String(describing: type(of: view))
        if typeName.contains("TerminalView") || typeName.contains("SwiftTerm") {
            return view
        }
        for subview in view.subviews {
            if let found = findSwiftTerm(in: subview) {
                return found
            }
        }
        return nil
    }

    // Forward mouse events to the terminal view
    override func mouseDown(with event: NSEvent) {
        if let terminal = findTerminalView() {
            terminal.mouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let terminal = findTerminalView() {
            terminal.mouseUp(with: event)
        } else {
            super.mouseUp(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let terminal = findTerminalView() {
            terminal.mouseDragged(with: event)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let terminal = findTerminalView() {
            terminal.rightMouseDown(with: event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if let terminal = findTerminalView() {
            terminal.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let terminal = findTerminalView() {
            terminal.keyUp(with: event)
        } else {
            super.keyUp(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let terminal = findTerminalView() {
            terminal.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

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
        if sender.draggingPasteboard.types?.contains(.string) == true {
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
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let position = calculateDropPosition(sender)
        isDragOver?.wrappedValue = false

        guard let uuidString = sender.draggingPasteboard.string(forType: .string),
              let tabID = UUID(uuidString: uuidString) else {
            print("[DROP] ❌ Failed to get UUID from pasteboard")
            return false
        }

        print("[DROP] ✅ Decoded: \(tabID), position: \(position)")
        onDrop?(tabID, position)
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
