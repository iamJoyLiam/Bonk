//
//  TabSplitDrag.swift
//  Bonk
//
//  Starts the system drag that a terminal pane already accepts, once a tab
//  drag has been recognized as downward. The pane then shows its own split
//  indicator and performs the split.
//

import AppKit
import SwiftUI

@MainActor
final class TabSplitDragLauncher: NSObject, NSDraggingSource {
    weak var view: NSView?

    func begin(tabID: UUID, title: String) -> Bool {
        guard let view,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged || event.type == .leftMouseDown,
              let host = view.window?.contentView
        else { return false }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(tabID.uuidString, forType: .string)
        let image = Self.badge(title)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let point = host.convert(event.locationInWindow, from: nil)
        let origin = NSPoint(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2)
        draggingItem.setDraggingFrame(NSRect(origin: origin, size: image.size), contents: image)
        host.beginDraggingSession(with: [draggingItem], event: event, source: self)
        return true
    }

    nonisolated func draggingSession(
        _: NSDraggingSession,
        sourceOperationMaskFor _: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    private static func badge(_ title: String) -> NSImage {
        let size = NSSize(width: AppStyle.tabMinWidth, height: AppStyle.tabHeight)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: size.height / 2, yRadius: size.height / 2).fill()
        let text = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: AppStyle.fontSmall),
            .foregroundColor: NSColor.labelColor,
        ]
        let bounds = text.size(withAttributes: attributes)
        let origin = NSPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2)
        text.draw(at: origin, withAttributes: attributes)
        image.unlockFocus()
        return image
    }
}

/// Keeps the launcher inside the window so a downward drag can find a view
/// to start the session from. It does not take clicks.
@MainActor
struct TabSplitDragHost: NSViewRepresentable {
    let launcher: TabSplitDragLauncher

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        launcher.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        launcher.view = nsView
    }
}
