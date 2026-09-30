//
//  PaneDropRouter.swift
//  Bonk
//
//  The decisions a terminal pane makes about a drag, with no view and no AppKit
//  involved, so each one can be tested on its own.
//
//  This replaces `DragDropNSView`, which owned the drop registration in a
//  sibling overlay that returned nil from `hitTest`. A sibling is not an
//  ancestor of the hit view, so the drop was never reachable — see
//  `PaneDropResolutionTests`.
//

import CoreGraphics
import Foundation

// MARK: - Drop position

/// Which edge of the pane a drop would split against.
enum DropPosition: String, Equatable, Sendable {
    case left, right, top, bottom

    var isHorizontal: Bool { self == .left || self == .right }
    var isVertical: Bool { self == .top || self == .bottom }
}

// MARK: - Payload

/// What a drag is carrying, once resolved.
enum PaneDropPayload: Equatable, Sendable {
    /// A tab being dragged in from the tab bar. Carried as a UUID string.
    case tab(UUID)
    /// Files being dragged in from Finder, for SFTP upload.
    case files([URL])
}

/// What the pane should do with a drag.
enum PaneDropAction: Equatable, Sendable {
    case moveTab(source: UUID, position: DropPosition)
    case uploadFiles([URL])
    /// Self-drop, an unreadable payload, or nothing recognisable.
    case reject
}

// MARK: - Router

/// Pure decisions for a pane drop.
///
/// File priority is preserved from the original implementation: files are routed
/// before a tab, so a drag carrying both uploads the files.
enum PaneDropRouter {

    /// The edge nearest the pointer. A degenerate size falls back to `.right`,
    /// matching the original.
    static func position(for point: CGPoint, in size: CGSize) -> DropPosition {
        let distLeft = point.x
        let distRight = size.width - point.x
        let distTop = size.height - point.y
        let distBottom = point.y

        guard size.width > 0, size.height > 0 else { return .right }

        let minDist = min(distLeft, distRight, distTop, distBottom)
        switch minDist {
        case distLeft: return .left
        case distRight: return .right
        case distTop: return .top
        default: return .bottom
        }
    }

    /// Parse a tab UUID. Returns nil for anything else — including arbitrary
    /// text dragged out of a terminal, which must never be mistaken for a tab.
    static func tabID(fromUUIDString value: String?) -> UUID? {
        guard let value, !value.isEmpty else { return nil }
        return UUID(uuidString: value)
    }

    /// Whether the split indicator should be showing.
    ///
    /// Only for a tab drag that is not a drop onto the tab it came from. A file
    /// drag shows no indicator, matching the original: files upload, they do
    /// not split.
    static func showsIndicator(for payload: PaneDropPayload?, currentTabID: UUID) -> Bool {
        guard case let .tab(sourceID) = payload else { return false }
        return sourceID != currentTabID
    }

    /// Route a resolved payload to an action.
    static func route(
        payload: PaneDropPayload?,
        currentTabID: UUID,
        position: DropPosition
    ) -> PaneDropAction {
        guard let payload else { return .reject }
        switch payload {
        case let .files(urls):
            // Original priority: files first.
            return urls.isEmpty ? .reject : .uploadFiles(urls)
        case let .tab(sourceID):
            guard sourceID != currentTabID else { return .reject }
            return .moveTab(source: sourceID, position: position)
        }
    }
}
