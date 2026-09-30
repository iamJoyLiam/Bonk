//
//  PaneDropDelegate.swift
//  Bonk
//
//  Adapts SwiftUI's drop API to the pane's existing callbacks.
//
//  This is deliberately thin: every decision it makes is in `PaneDropRouter`,
//  where it is testable without a view. What remains here is the part that
//  cannot be extracted — reading the payload off the drag, which is async, and
//  reporting positions to the indicator while the pointer moves.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os.log

/// Drop handler for a terminal pane.
///
/// Lives with the pane's SwiftUI container rather than in an overlay, so it is
/// an ancestor of the terminal view and therefore reachable when a drop is
/// resolved. The terminal keeps every click, scroll and selection, because this
/// type registers no hit test of its own.
@MainActor
struct PaneDropDelegate: DropDelegate {
    private static let logger = Logger(subsystem: "com.bonk", category: "PaneDrop")

    /// Types a terminal pane accepts.
    static let acceptedTypes: [UTType] = [.fileURL, .utf8PlainText, .plainText]
    private static let textTypes: [UTType] = [.utf8PlainText, .plainText]

    let currentTabID: UUID
    let sizeProvider: @MainActor () -> CGSize
    let onTabDrop: (UUID, DropPosition) -> Void
    let onFileDrop: ([URL]) -> Void
    let onDragStateChange: (Bool, DropPosition) -> Void

    /// Resolved payload, and the task resolving it.
    ///
    /// Resolution is async because `NSItemProvider` only vends contents on
    /// demand. The indicator must know whether this is a *tab* drag before it
    /// shows, and "is a parseable UUID" cannot be answered from the type
    /// identifier alone — dragging selected text out of a terminal also carries
    /// plain text. So the payload is resolved once and cached for the drag's
    /// duration, and the indicator follows the resolved value rather than
    /// guessing from the type.
    private final class State {
        var payload: PaneDropPayload?
        var loadTask: Task<Void, Never>?
        var lastPosition: DropPosition = .right
        var indicatorVisible = false
    }

    private let state = State()

    // MARK: - DropDelegate

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        let position = currentPosition(from: info)
        state.loadTask?.cancel()
        state.loadTask = Task { [self] in
            let payload = await Self.resolvePayload(from: info.itemProviders(for: Self.acceptedTypes))
            state.payload = payload
            state.lastPosition = position
            updateIndicator(payload: payload, position: position)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let position = currentPosition(from: info)
        state.lastPosition = position
        if state.indicatorVisible {
            // Only move an indicator that is already showing; a payload that is
            // not a tab drag must never raise one.
            onDragStateChange(true, position)
        } else {
            updateIndicator(payload: state.payload, position: position)
        }
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let position = currentPosition(from: info)
        let payload = state.payload
        hideIndicator()
        state.payload = nil

        switch PaneDropRouter.route(payload: payload, currentTabID: currentTabID, position: position) {
        case let .moveTab(source, dropPosition):
            onTabDrop(source, dropPosition)
            return true
        case let .uploadFiles(urls):
            onFileDrop(urls)
            return true
        case .reject:
            return false
        }
    }

    func dropExited(info: DropInfo) {
        state.loadTask?.cancel()
        state.loadTask = nil
        state.payload = nil
        hideIndicator()
    }

    // MARK: - Indicator

    private func currentPosition(from info: DropInfo) -> DropPosition {
        PaneDropRouter.position(for: info.location, in: sizeProvider())
    }

    private func updateIndicator(payload: PaneDropPayload?, position: DropPosition) {
        let shouldShow = PaneDropRouter.showsIndicator(for: payload, currentTabID: currentTabID)
        guard shouldShow != state.indicatorVisible else { return }
        state.indicatorVisible = shouldShow
        onDragStateChange(shouldShow, position)
    }

    private func hideIndicator() {
        guard state.indicatorVisible else { return }
        state.indicatorVisible = false
        onDragStateChange(false, state.lastPosition)
    }

    // MARK: - Payload resolution

    /// Read the drag's contents: files first, then a tab UUID — the original
    /// priority, so a drag carrying both uploads the files.
    static func resolvePayload(from providers: [NSItemProvider]) async -> PaneDropPayload? {
        if let urls = await loadURLs(from: providers), !urls.isEmpty {
            return .files(urls)
        }
        if let string = await loadString(from: providers),
           let tabID = PaneDropRouter.tabID(fromUUIDString: string)
        {
            return .tab(tabID)
        }
        return nil
    }

    private static func loadURLs(from providers: [NSItemProvider]) async -> [URL]? {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) })
        else { return nil }
        let url = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
        return url.map { [$0] }
    }

    private static func loadString(from providers: [NSItemProvider]) async -> String? {
        guard let provider = providers.first(where: { p in
            textTypes.contains { p.registeredTypeIdentifiers.contains($0.identifier) }
        }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier) { value, _ in
                if let text = value as? String {
                    continuation.resume(returning: text)
                } else if let data = value as? Data,
                          let text = String(data: data, encoding: .utf8)
                {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
