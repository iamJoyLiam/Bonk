//
//  DragDropView.swift
//  Bonk
//
//  AppKit drag-and-drop handler.
//  Handles tab drag (split pane) and file drag (SFTP upload).
//  Mouse/keyboard/scroll events pass through to terminal view.
//

import AppKit
import SwiftUI
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

/// AppKit NSView that handles drag-and-drop logic.
/// - Tab drag: splits pane
/// - File drag: uploads via SFTP
/// - Mouse/keyboard/scroll events: pass through to terminal view
class DragDropNSView: NSView {
    // MARK: - Properties

    /// Terminal view (not used for event forwarding, kept for reference)
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
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupDragTypes() {
        // Register for file and string drag types
        registerForDraggedTypes([
            .fileURL,
            .string,
            NSPasteboard.PasteboardType("public.data"),
            NSPasteboard.PasteboardType("public.item"),
        ])
    }

    // MARK: - Hit Testing

    /// Return nil to let events pass through to terminal view
    /// Only drag events will be intercepted by the drag destination protocol
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// Accept first mouse without requiring focus
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    // MARK: - Drag Destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let position = calculateDropPosition(sender)
        lastPosition = position
        isTrackingDrag = true

        // Only show indicator for tab drag, not file drag
        let isTabDrag = containsTabUUID(sender.draggingPasteboard) != nil
        if isTabDrag {
            onDragStateChange?(true, position)
        } else {
            onDragStateChange?(false, .right)
        }

        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let position = calculateDropPosition(sender)

        // Only notify if position changed (performance optimization)
        if position != lastPosition {
            lastPosition = position

            // Only show indicator for tab drag
            let isTabDrag = containsTabUUID(sender.draggingPasteboard) != nil
            if isTabDrag {
                onDragStateChange?(true, position)
            }
        }

        return .copy
    }

    override func draggingExited(_: NSDraggingInfo?) {
        isTrackingDrag = false
        onDragStateChange?(false, .right)
    }

    override func prepareForDragOperation(_: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTrackingDrag = false
        onDragStateChange?(false, .right)

        let pasteboard = sender.draggingPasteboard

        // Priority 1: Check for files
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            onFileDrop?(urls)
            return true
        }

        // Priority 2: Check for Tab UUID
        if let uuidString = pasteboard.string(forType: .string),
           let tabID = UUID(uuidString: uuidString)
        {
            let position = calculateDropPosition(sender)
            onTabDrop?(tabID, position)
            return true
        }

        return false
    }

    override func concludeDragOperation(_: NSDraggingInfo?) {
        isTrackingDrag = false
        onDragStateChange?(false, .right)
    }

    // MARK: - Helpers

    /// Calculate drop position based on mouse location
    private func calculateDropPosition(_ sender: NSDraggingInfo) -> DropPosition {
        let location = convert(sender.draggingLocation, from: nil)
        let width = bounds.width
        let height = bounds.height

        guard width > 0, height > 0 else { return .right }

        let distLeft = location.x
        let distRight = width - location.x
        let distTop = height - location.y
        let distBottom = location.y

        let minDist = min(distLeft, distRight, distTop, distBottom)

        switch minDist {
        case distLeft: return .left
        case distRight: return .right
        case distTop: return .top
        default: return .bottom
        }
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
}

// MARK: - SwiftUI Wrapper

/// SwiftUI wrapper for DragDropNSView
struct DragDropView: NSViewRepresentable {
    let terminalView: NSView?
    let onTabDrop: (UUID, DropPosition) -> Void
    let onFileDrop: ([URL]) -> Void
    let onDragStateChange: (Bool, DropPosition) -> Void

    func makeNSView(context _: Context) -> DragDropNSView {
        let view = DragDropNSView()
        view.terminalView = terminalView
        view.onTabDrop = onTabDrop
        view.onFileDrop = onFileDrop
        view.onDragStateChange = onDragStateChange
        return view
    }

    func updateNSView(_ nsView: DragDropNSView, context _: Context) {
        nsView.terminalView = terminalView
        nsView.onTabDrop = onTabDrop
        nsView.onFileDrop = onFileDrop
        nsView.onDragStateChange = onDragStateChange
    }
}
