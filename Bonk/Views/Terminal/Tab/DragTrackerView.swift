//
//  DragTrackerView.swift
//  Bonk
//
//  AppKit NSView that tracks drag position for region indicator.
//  Does NOT handle the actual drop - that's done by SwiftUI's .onDrop.
//

import SwiftUI

#if os(macOS)
import AppKit

/// SwiftUI wrapper for the drag tracker.
struct DragTrackerView: View {
    @Binding var isDragOver: Bool
    @Binding var dropPosition: DropPosition

    var body: some View {
        DragTrackerNSViewRepresentable(
            isDragOver: $isDragOver,
            dropPosition: $dropPosition
        )
    }
}

/// AppKit NSView that tracks drag position.
private class DragTrackerNSView: NSView {
    var isDragOver: Binding<Bool>?
    var dropPosition: Binding<DropPosition>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Register for string type to detect drags
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Don't block clicks
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
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

    // Don't handle the actual drop - let SwiftUI's .onDrop handle it
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return false
    }
}

/// NSViewRepresentable wrapper.
private struct DragTrackerNSViewRepresentable: NSViewRepresentable {
    @Binding var isDragOver: Bool
    @Binding var dropPosition: DropPosition

    func makeNSView(context: Context) -> DragTrackerNSView {
        let v = DragTrackerNSView()
        v.isDragOver = $isDragOver
        v.dropPosition = $dropPosition
        return v
    }

    func updateNSView(_ nsView: DragTrackerNSView, context: Context) {
        nsView.isDragOver = $isDragOver
        nsView.dropPosition = $dropPosition
    }
}
#endif
