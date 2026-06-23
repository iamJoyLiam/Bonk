//
//  DragDropView.swift
//  Bonk
//
//  AppKit drag-and-drop handler with event forwarding.
//  Handles tab drag (split pane) and file drag (SFTP upload).
//  Forwards mouse/keyboard/scroll events to terminal view.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Drop Position

/// Drop position for split pane
enum DropPosition: String {
    case left, right, top, bottom

    var isHorizontal: Bool {
        self == .left || self == .right
    }

    var isVertical: Bool {
        self == .top || self == .bottom
    }
}

// MARK: - Drag Drop NSView

/// AppKit NSView that handles all drag-and-drop logic.
/// - Tab drag: splits pane
/// - File drag: uploads via SFTP
/// - Other events: forwarded to terminal view
class DragDropNSView: NSView {

    // MARK: - Properties

    /// Terminal view to forward events to
    weak var terminalView: NSView?

    /// Callback when tab is dropped (for split pane)
    var onTabDrop: ((UUID, DropPosition) -> Void)?

    /// Callback when files are dropped (for upload)
    var onFileDrop: (([URL]) -> Void)?

    /// Callback when drag state changes (for indicator)
    var onDragStateChange: ((Bool, DropPosition) -> Void)?

    /// Last calculated drop position (cached for performance)
    private var lastPosition: DropPosition = .right

    /// Whether we are currently tracking a drag
    private var isTrackingDrag = false

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupDragTypes()
        log("init")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        log("deinit")
    }

    private func setupDragTypes() {
        // Register for file and string drag types
        registerForDraggedTypes([
            .fileURL,
            .string,
            NSPasteboard.PasteboardType("public.data"),
            NSPasteboard.PasteboardType("public.item")
        ])
        log("setupDragTypes: registered [.fileURL, .string, public.data, public.item]")
    }

    // MARK: - Hit Testing

    /// Return self to receive all events
    override func hitTest(_ point: NSPoint) -> NSView? {
        return self
    }

    /// Accept first mouse without requiring focus
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // MARK: - Drag Destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let position = calculateDropPosition(sender)
        lastPosition = position
        isTrackingDrag = true

        let types = sender.draggingPasteboard.types?.map { $0.rawValue } ?? []
        log("draggingEntered: types=\(types), position=\(position)")

        // Only show indicator for tab drag, not file drag
        let isTabDrag = containsTabUUID(sender.draggingPasteboard) != nil
        if isTabDrag {
            log("draggingEntered: TAB drag, showing indicator")
            onDragStateChange?(true, position)
        } else {
            log("draggingEntered: FILE drag, no indicator")
            onDragStateChange?(false, .right)
        }

        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let position = calculateDropPosition(sender)

        // Only notify if position changed (performance optimization)
        if position != lastPosition {
            lastPosition = position
            log("draggingUpdated: position=\(position)")

            // Only show indicator for tab drag
            let isTabDrag = containsTabUUID(sender.draggingPasteboard) != nil
            if isTabDrag {
                onDragStateChange?(true, position)
            }
        }

        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        log("draggingExited")
        isTrackingDrag = false
        onDragStateChange?(false, .right)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        log("prepareForDragOperation: returning true")
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTrackingDrag = false
        onDragStateChange?(false, .right)

        let pasteboard = sender.draggingPasteboard
        let types = pasteboard.types?.map { $0.rawValue } ?? []
        log("performDragOperation: types=\(types)")

        // Priority 1: Check for files
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            log("performDragOperation: FILE drag detected, \(urls.count) file(s)")
            for (index, url) in urls.enumerated() {
                log("  [\(index)] \(url.path)")
            }
            onFileDrop?(urls)
            return true
        }

        // Priority 2: Check for Tab UUID
        if let uuidString = pasteboard.string(forType: .string) {
            log("performDragOperation: STRING drag detected: \(uuidString)")
            if let tabID = UUID(uuidString: uuidString) {
                let position = calculateDropPosition(sender)
                log("performDragOperation: TAB drag detected, id=\(tabID), position=\(position)")
                onTabDrop?(tabID, position)
                return true
            } else {
                log("performDragOperation: STRING is not a valid UUID, ignoring")
            }
        }

        log("performDragOperation: UNKNOWN drag type, returning false")
        return false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        log("concludeDragOperation")
        isTrackingDrag = false
        onDragStateChange?(false, .right)
    }

    // MARK: - Event Forwarding (Mouse)

    override func mouseDown(with event: NSEvent) {
        log("mouseDown: forwarding to terminal")
        terminalView?.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        log("mouseUp: forwarding to terminal")
        terminalView?.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        log("mouseDragged: forwarding to terminal")
        terminalView?.mouseDragged(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        log("rightMouseDown: forwarding to terminal")
        terminalView?.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        log("rightMouseUp: forwarding to terminal")
        terminalView?.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        log("rightMouseDragged: forwarding to terminal")
        terminalView?.rightMouseDragged(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        log("otherMouseDown: forwarding to terminal")
        terminalView?.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        log("otherMouseUp: forwarding to terminal")
        terminalView?.otherMouseUp(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        log("otherMouseDragged: forwarding to terminal")
        terminalView?.otherMouseDragged(with: event)
    }

    // MARK: - Event Forwarding (Keyboard)

    override func keyDown(with event: NSEvent) {
        log("keyDown: forwarding to terminal")
        terminalView?.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        log("keyUp: forwarding to terminal")
        terminalView?.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        log("flagsChanged: forwarding to terminal")
        terminalView?.flagsChanged(with: event)
    }

    // MARK: - Event Forwarding (Scroll)

    override func scrollWheel(with event: NSEvent) {
        log("scrollWheel: forwarding to terminal")
        terminalView?.scrollWheel(with: event)
    }

    // MARK: - Event Forwarding (Magnification)

    override func magnify(with event: NSEvent) {
        log("magnify: forwarding to terminal")
        terminalView?.magnify(with: event)
    }

    // MARK: - Helpers

    /// Calculate drop position based on mouse location
    private func calculateDropPosition(_ sender: NSDraggingInfo) -> DropPosition {
        let location = convert(sender.draggingLocation, from: nil)
        let w = bounds.width
        let h = bounds.height

        guard w > 0, h > 0 else {
            log("calculateDropPosition: bounds is zero, returning .right")
            return .right
        }

        let distLeft = location.x
        let distRight = w - location.x
        let distTop = h - location.y
        let distBottom = location.y

        let minDist = min(distLeft, distRight, distTop, distBottom)

        let position: DropPosition
        switch minDist {
        case distLeft: position = .left
        case distRight: position = .right
        case distTop: position = .top
        default: position = .bottom
        }

        return position
    }

    /// Check if pasteboard contains files
    private func containsFiles(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return true
        }
        return false
    }

    /// Check if pasteboard contains Tab UUID
    private func containsTabUUID(_ pasteboard: NSPasteboard) -> UUID? {
        guard let uuidString = pasteboard.string(forType: .string) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        // Logging disabled for production
        // print("[DRAG_DROP] \(message)")
    }
}

// MARK: - SwiftUI Wrapper

/// SwiftUI wrapper for DragDropNSView
struct DragDropView: NSViewRepresentable {
    let terminalView: NSView?
    let onTabDrop: (UUID, DropPosition) -> Void
    let onFileDrop: ([URL]) -> Void
    let onDragStateChange: (Bool, DropPosition) -> Void

    func makeNSView(context: Context) -> DragDropNSView {
        let view = DragDropNSView()
        view.terminalView = terminalView
        view.onTabDrop = onTabDrop
        view.onFileDrop = onFileDrop
        view.onDragStateChange = onDragStateChange
        return view
    }

    func updateNSView(_ nsView: DragDropNSView, context: Context) {
        nsView.terminalView = terminalView
        nsView.onTabDrop = onTabDrop
        nsView.onFileDrop = onFileDrop
        nsView.onDragStateChange = onDragStateChange
    }
}
