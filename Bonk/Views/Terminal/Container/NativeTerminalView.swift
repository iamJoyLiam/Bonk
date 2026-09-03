//
//  NativeTerminalView.swift
//  Bonk
//
//  Intercepts AppKit's physical layout cycle to capture accurate terminal dimensions.
//  Eliminates SwiftUI lifecycle timing issues that cause Vim half-screen rendering.
//  Also hosts the Warp-style inline AI completion (ghost text + Tab/Esc handling).
//

import os
import SwiftTerm

#if os(macOS)
    import AppKit

    /// Custom TerminalView that intercepts AppKit's physical layout completion.
    /// Only fires PTY sync when the system has finalized pixel-level frame calculation.
    /// Main-thread confined; declared @unchecked Sendable so completion tasks can
    /// reference it weakly (same pattern as ContainerTerminalCoordinator).
    final class NativeTerminalView: SwiftTerm.TerminalView, @unchecked Sendable {
        /// Called when AppKit completes physical layout with accurate cols/rows.
        var onPhysicalLayout: ((Int, Int) -> Void)?

        /// Provides the terminal context (typed text, cwd, history, output) used
        /// to build inline completion requests. Set by the owning pane.
        var completionContextProvider: (@MainActor () -> InlineCompletionContext)?

        private var lastSyncedCols = -1
        private var lastSyncedRows = -1
        private nonisolated(unsafe) var resizeDebounceTask: Task<Void, Never>?
        private var pendingResize: (Int, Int)?

        /// Scroll sensitivity multiplier (exposed for setting from preferences).
        /// This wraps SwiftTerm's native scrollSensitivity property.
        var scrollSensitivityMultiplier: CGFloat = 1.0 {
            didSet {
                self.scrollSensitivity = scrollSensitivityMultiplier
            }
        }

        // MARK: - Focus Ring

        override init(frame frameRect: NSRect, font: NSFont?) {
            super.init(frame: frameRect, font: font)
            focusRingType = .none
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            focusRingType = .none
        }

        // MARK: - Inline Completion

        let completionService = InlineCompletionService.shared
        private nonisolated(unsafe) var completionDebounceTask: Task<Void, Never>?
        var ghostOverlay: InlineGhostOverlay?
        // Ghost updates coalesced to display tick — LLM streams many deltas per frame.
        nonisolated(unsafe) var ghostCoalesceTask: Task<Void, Never>?
        private nonisolated(unsafe) var resignObserver: NSObjectProtocol?
        nonisolated(unsafe) var rightClickMonitor: Any?

        override func layout() {
            super.layout()

            let cols = self.terminal.cols
            let rows = self.terminal.rows

            // Block invalid zero-value sizes (e.g., when tab is hidden)
            guard cols > 0, rows > 0 else { return }

            // Filter duplicate dimensions to avoid redundant SIGWINCH signals
            guard cols != lastSyncedCols || rows != lastSyncedRows else {
                positionGhostOverlay()
                return
            }

            lastSyncedCols = cols
            lastSyncedRows = rows
            pendingResize = (cols, rows)

            // Coalesce rapid layout storms (splitter drag triggers dozens of layouts/s)
            // into at most one SIGWINCH per display frame.
            resizeDebounceTask?.cancel()
            resizeDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self, let pending = self.pendingResize else { return }
                // Clear pending before firing so a new layout during the callback
                // schedules a fresh debounce instead of being swallowed.
                self.pendingResize = nil
                self.onPhysicalLayout?(pending.0, pending.1)
            }
            positionGhostOverlay()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer = resignObserver {
                NotificationCenter.default.removeObserver(observer)
                resignObserver = nil
            }
            if let monitor = rightClickMonitor {
                NSEvent.removeMonitor(monitor)
                rightClickMonitor = nil
            }
            guard let window else {
                MainActor.assumeIsolated {
                    completionService.dismiss()
                    hideGhost(reason: "window-nil")
                }
                return
            }
            // Fires when the window's key status or first responder changes.
            // Only hide the ghost visually — transient focus shifts shouldn't
            // destroy the suggestion state; it re-shows on the next layout
            // when focus is back.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          self.completionService.isRequesting || !self.completionService.suggestion.isEmpty
                    else { return }
                    if self.window?.isKeyWindow == true, self.window?.firstResponder === self {
                        // Focus is back — re-show a suggestion that was hidden
                        // by a transient resign.
                        if !self.completionService.suggestion.isEmpty {
                            self.showGhost(text: self.completionService.suggestion)
                        }
                    } else {
                        self.hideGhost(reason: "resign")
                    }
                }
            }
            installRightClickPasteMonitor()
        }

        deinit {
            completionDebounceTask?.cancel()
            resizeDebounceTask?.cancel()
            ghostCoalesceTask?.cancel()
            if let observer = resignObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let monitor = rightClickMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        // MARK: - Key Handling

        /// Intercept keys while a suggestion is active: Tab accepts, Esc dismisses,
        /// any other key dismisses and forwards. Typing schedules a debounced request.
        /// Returns nil when the event was consumed, otherwise the event to forward.
        /// Called from the coordinator's keyDown monitor (before SwiftTerm's keyDown).
        /// The monitor always fires on the main thread.
        nonisolated func processKeyEvent(_ event: NSEvent) -> NSEvent? {
            // Extract everything from the event first — NSEvent is not Sendable,
            // so it must not cross into the MainActor closures below.
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

            // App shortcuts handled directly (window-scoped, not
            // first-responder-scoped) so they work even when the AI panel's
            // text field holds focus, and the menu's FocusedValue chain can't
            // swallow them. Event is consumed to avoid double-firing.
            if !ShortcutManager.isRecording,
               let shortcut = MainActor.assumeIsolated({
                   shortcutNotification(for: keyCode, modifiers: modifiers)
               }),
               event.window === MainActor.assumeIsolated({ window })
            {
                NotificationCenter.default.post(name: shortcut, object: nil)
                return nil
            }
            // Esc closes the search bar when it's open.
            if keyCode == 53, MainActor.assumeIsolated({ TerminalSearchState.isActive }) {
                NotificationCenter.default.post(name: .toggleTerminalSearch, object: nil)
                return nil
            }
            // Enter — the command is running. Drop any pending suggestion and
            // never arm a new request, or the ghost would render over the
            // command's output.
            if keyCode == 36 || keyCode == 76 {
                MainActor.assumeIsolated {
                    completionDebounceTask?.cancel()
                    completionService.dismiss()
                    hideGhost(reason: "enter")
                }
                return event
            }

            let eventModifiers = event.modifierFlags
            let eventCharacters = event.characters
            let shouldSchedule = MainActor.assumeIsolated {
                shouldTriggerCompletion(
                    keyCode: keyCode,
                    modifiers: eventModifiers,
                    characters: eventCharacters
                )
            }

            let isFocused = MainActor.assumeIsolated { window?.firstResponder === self }
            guard isFocused else { return event }

            let hasSuggestion = MainActor.assumeIsolated { !completionService.suggestion.isEmpty }

            if hasSuggestion {
                if keyCode == 48, modifiers.isEmpty {
                    // Tab — accept the suggestion, do not forward a real tab.
                    acceptSuggestion()
                    return nil
                }
                if keyCode == 53 {
                    // Esc — dismiss only.
                    completionDebounceTask?.cancel()
                    MainActor.assumeIsolated {
                        completionService.dismiss(rejected: true)
                        hideGhost(reason: "esc")
                    }
                    return nil
                }
                // Any other key — dismiss and forward normally.
                MainActor.assumeIsolated {
                    completionService.dismiss(rejected: true)
                    hideGhost(reason: "other-key")
                }
            }

            if shouldSchedule {
                // A new request is starting — drop any stale ghost text so the
                // old suggestion doesn't linger while the model thinks.
                MainActor.assumeIsolated {
                    hideGhost(reason: "new-typing")
                    scheduleCompletion()
                }
            }
            return event
        }

        /// Map app shortcuts to notifications. Returns nil for keys the
        /// terminal should handle normally (or that the menu handles).
        /// Reads the user's configured shortcuts, so custom key bindings work
        /// even when the menu FocusedValue chain is broken.
        /// Linear scan over ~10 cases is negligible per keyDown (<0.01ms).
        private func shortcutNotification(
            for keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags
        ) -> Notification.Name? {
            for action in ShortcutAction.allCases {
                guard let equivalent = ShortcutManager.shared.keyEquivalent(for: action),
                      equivalent.keyCode == keyCode,
                      equivalent.modifiers.nsModifierFlags == modifiers,
                      let notification = Self.notification(for: action)
                else { continue }
                return notification
            }
            return nil
        }

        private static func notification(for action: ShortcutAction) -> Notification.Name? {
            switch action {
            case .newTerminal: .terminalNewTab
            case .closeTab: .terminalCloseTab
            case .closePane: .terminalClosePane
            case .find: .toggleTerminalSearch
            case .reconnect: .terminalReconnect
            case .clearTerminal: .terminalClear
            case .splitHorizontal: .terminalSplitHorizontal
            case .splitVertical: .terminalSplitVertical
            case .sftpBrowser: .toggleSFTP
            case .aiAssistant: .toggleAIChat
            case .nextTab, .previousTab, .settings: nil
            }
        }

        /// Only plain typing (printable characters, backspace/delete) should
        /// arm the completion debounce — not shortcuts, arrows, or modifiers.
        private func shouldTriggerCompletion(
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags,
            characters: String?
        ) -> Bool {
            guard keyCode != 53 else { return false } // Esc is never typing
            guard modifiers.isDisjoint(with: [.command, .control]) else { return false }
            if keyCode == 51 || keyCode == 117 { return true }
            return !(characters?.isEmpty ?? true)
        }

        // MARK: - Completion Flow

        private func scheduleCompletion() {
            completionDebounceTask?.cancel()
            let debounceMs = MainActor.assumeIsolated { completionService.debounceMilliseconds }
            completionDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Double(debounceMs)))
                guard !Task.isCancelled else { return }
                self?.requestCompletion()
            }
        }

        @MainActor
        private func requestCompletion() {
            guard completionService.isEnabled,
                  !terminal.isCurrentBufferAlternate, // vim / less / man: no completion
                  let contextProvider = completionContextProvider else { return }

            let (cursorX, cursorY) = terminal.getCursorLocation()
            let yDisp = terminal.getTopVisibleRow()

            // The cursor must be on the last screen row — i.e. typing at a prompt.
            // At the bottom of the buffer (yDisp == yBase) the cursor row from
            // getCursorLocation() equals the screen row. scrollPosition hits 1.0
            // only when scrolled to the end; yDisp == 0 covers buffers smaller
            // than the viewport.
            let atBottom = scrollPosition >= 1.0 || yDisp == 0
            // Prefer OSC 133 prompt marks when the shell emits them (semantic
            // prompt integration); fall back to the bottom-of-buffer heuristic
            // for shells without the integration.
            let bufferRow = yDisp + cursorY
            let onPromptRow: Bool
            if let rowKind = terminal.semanticRowKind(at: bufferRow) {
                onPromptRow = rowKind == .initial || rowKind == .continuation
            } else {
                onPromptRow = atBottom
            }
            guard onPromptRow, cursorY >= 0, cursorY < terminal.rows,
                  let line = terminal.getLine(row: cursorY) else { return }

            let baseContext = contextProvider()
            let raw = line.translateToString(trimRight: true)
            guard let typed = resolveTypedText(raw: raw, inputBuffer: baseContext.inputBuffer),
                  typed.count >= 2 else { return }

            // Only complete when the cursor sits at the end of the line.
            guard cursorX >= line.getTrimmedLength() - 3 else { return }

            var context = baseContext
            context.inputBuffer = typed
            completionService.request(context: context) { [weak self] text in
                guard let self else { return }
                self.showGhost(text: text)
            }
            // No instant history match — show a subtle pending indicator so a
            // slow model doesn't look like it silently gave up.
            if completionService.suggestion.isEmpty {
                showWaiting()
            }
        }

        /// Pick the command text to complete: prefer the pure typed buffer when it
        /// is really the tail of the visible line, else fall back to prompt stripping.
        private func resolveTypedText(raw: String, inputBuffer: String) -> String? {
            let typed = inputBuffer.trimmingCharacters(in: .whitespaces)
            if typed.count >= 2, raw.hasSuffix(typed) { return typed }
            return InlineCompletionService.commandText(from: raw)
        }

        /// Accept the current suggestion: send its text through the normal input
        /// path (history recording and broadcast included), then clear it.
        private nonisolated func acceptSuggestion() {
            MainActor.assumeIsolated {
                let text = completionService.accept()
                hideGhost(reason: "accept")
                guard !text.isEmpty else { return }
                // Respect bracketed paste mode when inserting accepted ghost text
                let payload: String
                if self.terminal.bracketedPasteMode {
                    payload = "\u{1B}[200~" + text + "\u{1B}[201~"
                } else {
                    payload = text
                }
                let bytes = ArraySlice(payload.utf8)
                // Same forwarding as SwiftTerm's internal send — goes through
                // onSend → SessionManager → InputHandler (history preserved).
                terminalDelegate?.send(source: self, data: bytes)
            }
        }

        /// Mirror of SwiftTerm's cell dimension computation for the current font.
        static func cellSize(for font: NSFont, backingScale: CGFloat) -> CGSize {
            let ascent = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            let leading = CTFontGetLeading(font)
            let cellHeight = ceil(ascent + descent + leading)
            let glyph = font.glyph(withName: "W")
            let cellWidth = font.advancement(forGlyph: glyph).width
            let snappedWidth = ceil(cellWidth * backingScale) / backingScale
            let snappedHeight = ceil(cellHeight * backingScale) / backingScale
            return CGSize(
                width: max(1, snappedWidth),
                height: max(1, min(snappedHeight, 8192))
            )
        }
    }

#endif
