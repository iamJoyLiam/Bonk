//
//  TerminalSelectionResponder.swift
//  Bonk
//
//  Answers `.requestTerminalSelection` from the terminal the user is actually
//  looking at.
//
//  This used to be handled inside `TerminalContainerView`, which was wrong
//  twice over:
//
//  1. It replied with `notification.object as? String ?? ""`. Every sender
//     posts `object: nil`, so it always answered with the empty string and
//     never once called `getSelection()`. The AI panel therefore received
//     "" and silently opened with no text.
//  2. `TerminalContainerView` is the *single-pane* terminal. A split tab renders
//     `PaneTerminalView` instead, so no observer existed at all and the request
//     went unanswered until the caller's timeout fired.
//
//  Resolving the target centrally also removes the ambiguity of a response
//  carrying no identity: previously every live terminal posted a reply, and a
//  caller took whichever arrived first.
//

import AppKit
import Foundation
import SwiftTerm
import os.log

/// Single owner of the `.requestTerminalSelection` -> `.terminalSelectionResponse`
/// round trip.
///
/// Installed once, by the app delegate, rather than by whichever terminal view
/// happens to be on screen.
@MainActor
final class TerminalSelectionResponder {
    private static let logger = Logger(subsystem: "com.bonk", category: "TerminalSelection")

    private let sessionManager: SessionManager
    private var observer: (any NSObjectProtocol)?

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    /// Begin answering selection requests.
    ///
    /// There is deliberately no `deinit` cleanup: a `@MainActor` `deinit` is
    /// nonisolated and cannot touch this observer. The app installs one responder
    /// for the process lifetime, which needs no teardown; tests call `stop()`.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .requestTerminalSelection,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.respond() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Answer with the active terminal's real selection.
    ///
    /// The request carries no identity, so "the selection" means the selection
    /// in the active pane of the active tab — resolved through the same cache
    /// lookup Copy uses, which is the only place that knows whether a view is
    /// keyed by pane or by tab.
    ///
    /// When there is no terminal to ask, no response is posted. The caller has
    /// a timeout and a sensible fallback; inventing an empty response here
    /// would be indistinguishable from "you have no selection", which is a
    /// different thing.
    private func respond() {
        guard let tab = sessionManager.activeTab else { return }
        guard let cached = TerminalViewCache.shared.retrieveActivePane(
            tabID: tab.id,
            activePaneID: tab.activePaneID
        ) else {
            Self.logger.debug("No terminal view for active tab; leaving request unanswered")
            return
        }
        let selection = cached.view.getSelection() ?? ""
        NotificationCenter.default.post(name: .terminalSelectionResponse, object: selection)
    }
}
