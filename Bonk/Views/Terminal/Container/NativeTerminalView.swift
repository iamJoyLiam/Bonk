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

        /// Scroll sensitivity multiplier (exposed for setting from preferences).
        /// This wraps SwiftTerm's native scrollSensitivity property.
        var scrollSensitivityMultiplier: CGFloat = 1.0 {
            didSet {
                self.scrollSensitivity = scrollSensitivityMultiplier
            }
        }

        // MARK: - Inline Completion

        private let completionService = InlineCompletionService.shared
        private var completionDebounceTask: Task<Void, Never>?
        private var ghostOverlay: InlineGhostOverlay?
        private nonisolated(unsafe) var resignObserver: NSObjectProtocol?

        override func layout() {
            super.layout()

            let cols = self.terminal.cols
            let rows = self.terminal.rows

            // Block invalid zero-value sizes (e.g., when tab is hidden)
            guard cols > 0, rows > 0 else { return }

            // Filter duplicate dimensions to avoid redundant SIGWINCH signals
            guard cols != lastSyncedCols || rows != lastSyncedRows else { return }

            lastSyncedCols = cols
            lastSyncedRows = rows

            // At this point, AppKit has finalized the frame — dimensions are 100% accurate
            onPhysicalLayout?(cols, rows)
            positionGhostOverlay()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer = resignObserver {
                NotificationCenter.default.removeObserver(observer)
                resignObserver = nil
            }
            guard let window else {
                MainActor.assumeIsolated {
                    completionService.dismiss()
                    hideGhost()
                }
                return
            }
            // Fires when the window's key status or first responder changes.
            // The suggestion belongs to the focused pane — drop it otherwise.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          self.completionService.isRequesting || !self.completionService.suggestion.isEmpty
                    else { return }
                    if !(self.window?.isKeyWindow ?? false) || self.window?.firstResponder !== self {
                        self.completionService.dismiss()
                        self.hideGhost()
                    }
                }
            }
        }

        deinit {
            completionDebounceTask?.cancel()
            if let observer = resignObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        // MARK: - Key Handling

        /// Intercept keys while a suggestion is active: Tab accepts, Esc dismisses,
        /// any other key dismisses and forwards. Typing schedules a debounced request.
        /// Returns nil when the event was consumed, otherwise the event to forward.
        /// Called from the coordinator's keyDown monitor (before SwiftTerm's keyDown).
        /// `nonisolated(unsafe)`: the monitor always fires on the main thread.
        nonisolated(unsafe) func processKeyEvent(_ event: NSEvent) -> NSEvent? {
            // Extract everything from the event first — NSEvent is not Sendable,
            // so it must not cross into the MainActor closures below.
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

            // Cmd+F toggles terminal search. The SwiftUI menu shortcut can miss
            // when focus is odd, so handle the key directly (only while focused).
            if keyCode == 3, modifiers == [.command] {
                let isFocused = MainActor.assumeIsolated { window?.firstResponder === self }
                if isFocused {
                    NotificationCenter.default.post(name: .toggleTerminalSearch, object: nil)
                    return nil
                }
            }
            // Esc closes the search bar when it's open.
            if keyCode == 53, MainActor.assumeIsolated({ TerminalSearchState.isActive }) {
                NotificationCenter.default.post(name: .toggleTerminalSearch, object: nil)
                return nil
            }

            let shouldSchedule = shouldTriggerCompletion(
                keyCode: keyCode,
                modifiers: event.modifierFlags,
                characters: event.characters
            )

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
                    MainActor.assumeIsolated {
                        completionService.dismiss()
                        hideGhost()
                    }
                    return nil
                }
                // Any other key — dismiss and forward normally.
                MainActor.assumeIsolated {
                    completionService.dismiss()
                    hideGhost()
                }
            }

            if shouldSchedule {
                // A new request is starting — drop any stale ghost text so the
                // old suggestion doesn't linger while the model thinks.
                MainActor.assumeIsolated {
                    hideGhost()
                }
                scheduleCompletion()
            }
            return event
        }

        /// Only plain typing (printable characters, backspace/delete) should
        /// arm the completion debounce — not shortcuts, arrows, or modifiers.
        private func shouldTriggerCompletion(
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags,
            characters: String?
        ) -> Bool {
            guard modifiers.isDisjoint(with: [.command, .control]) else { return false }
            if keyCode == 51 || keyCode == 117 { return true }
            return !(characters?.isEmpty ?? true)
        }

        /// Called by the coordinator whenever remote output is fed into the
        /// terminal — the shell state changed, so the suggestion is stale.
        func handleRemoteOutput() {
            MainActor.assumeIsolated {
                guard completionService.isRequesting || !completionService.suggestion.isEmpty else { return }
                completionService.dismiss()
                hideGhost()
            }
        }

        /// Called by the coordinator when the user scrolls away from the bottom —
        /// the prompt (and any ghost text) is no longer in view.
        func handleScroll(position: Double) {
            MainActor.assumeIsolated {
                guard position < 1.0,
                      completionService.isRequesting || !completionService.suggestion.isEmpty else { return }
                completionService.dismiss()
                hideGhost()
            }
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
                  let contextProvider = completionContextProvider else { return }

            let (cursorX, cursorY) = terminal.getCursorLocation()
            let yDisp = terminal.getTopVisibleRow()

            // The cursor must be on the last screen row — i.e. typing at a prompt.
            // At the bottom of the buffer (yDisp == yBase) the cursor row from
            // getCursorLocation() equals the screen row. scrollPosition hits 1.0
            // only when scrolled to the end; yDisp == 0 covers buffers smaller
            // than the viewport. Alternate screens (vim, less) never satisfy this.
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
        private nonisolated(unsafe) func acceptSuggestion() {
            MainActor.assumeIsolated {
                let text = completionService.accept()
                hideGhost()
                guard !text.isEmpty else { return }
                let bytes = ArraySlice(text.utf8)
                // Same forwarding as SwiftTerm's internal send — goes through
                // onSend → SessionManager → InputHandler (history preserved).
                terminalDelegate?.send(source: self, data: bytes)
            }
        }

        // MARK: - Ghost Overlay

        private func ensureGhostOverlay() -> InlineGhostOverlay {
            if let ghostOverlay { return ghostOverlay }
            let overlay = InlineGhostOverlay()
            overlay.font = font
            addSubview(overlay, positioned: .above, relativeTo: nil)
            ghostOverlay = overlay
            return overlay
        }

        @MainActor
        private func showGhost(text: String) {
            guard window?.firstResponder === self else { return }
            guard !text.isEmpty else {
                hideGhost()
                return
            }
            let overlay = ensureGhostOverlay()
            overlay.font = font
            // Skip redundant updates — same text re-renders on every stream
            // chunk and that is what makes the ghost look like it is jittering.
            if overlay.text == text { return }
            overlay.text = text
            overlay.isHidden = false
            positionGhostOverlay()
        }

        @MainActor
        private func hideGhost() {
            ghostOverlay?.isHidden = true
            ghostOverlay?.text = ""
        }

        /// Place the ghost text right after the terminal cursor.
        private func positionGhostOverlay() {
            guard let overlay = ghostOverlay, !overlay.isHidden, !overlay.text.isEmpty else { return }
            let cell = Self.cellSize(for: font, backingScale: window?.backingScaleFactor ?? 2)
            let (cursorX, cursorY) = terminal.getCursorLocation()
            let yDisp = terminal.getTopVisibleRow()

            // Same bottom-of-buffer gate as requestCompletion: at the bottom the
            // cursor row equals the screen row; otherwise skip (off-screen).
            let atBottom = scrollPosition >= 1.0 || yDisp == 0
            guard atBottom, cursorY >= 0, cursorY < terminal.rows else {
                overlay.isHidden = true
                return
            }

            let originX = CGFloat(cursorX) * cell.width
            let available = max(0, bounds.width - originX)
            // Keep the frame width fixed to the remaining line space: the text
            // grows inside it while streaming, so the overlay never re-measures
            // per delta (which caused visible jitter).
            let width = available
            overlay.frame = NSRect(
                x: originX,
                y: bounds.height - CGFloat(cursorY + 1) * cell.height,
                width: width,
                height: cell.height
            )
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
