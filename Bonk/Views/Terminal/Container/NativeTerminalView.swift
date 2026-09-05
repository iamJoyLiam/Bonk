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

        /// Intelligence-owned snapshot provider (single source of truth)
        var commandSnapshotProvider: (@MainActor () -> CommandContextSnapshot)?
        /// Single pipeline (Intelligence owns inline)
        var inlinePipeline: InlineSuggestionPipeline? {
            didSet { bindPipeline() }
        }

        private nonisolated(unsafe) var pendingCompletionTask: Task<Void, Never>?

        private func bindPipeline() {
            guard let pipeline = inlinePipeline else { return }
            pipeline.onSuggestionChanged = { [weak self] sug in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let s = sug {
                        let textToDisplay: String
                        let (_, cursorY) = self.terminal.getCursorLocation()
                        if cursorY >= 0, cursorY < self.terminal.rows,
                           let line = self.terminal.getLine(row: cursorY) {
                            let raw = line.translateToString(trimRight: true)
                            textToDisplay = CommandEditor.alignedAcceptSuffix(suggestion: s.displayText, rawLine: raw) ?? s.displayText
                        } else {
                            textToDisplay = s.displayText
                        }
                        if !textToDisplay.isEmpty {
                            self.showGhost(text: textToDisplay)
                        } else {
                            self.hideGhost(reason: "aligned-empty")
                        }
                    } else {
                        self.hideGhost(reason: "pipeline-nil")
                    }
                }
            }
            pipeline.onCandidatesChanged = { [weak self] count, engagement in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let enabled = UserDefaults.standard.object(forKey: "ai_inline_candidate_popup") as? Bool ?? true
                    guard enabled, count > 1 else {
                        self.hideCandidateList()
                        return
                    }
                    // Popup rows show the FULL command; ghost keeps showing the
                    // selected candidate's continuation suffix.
                    guard let pipeline = self.inlinePipeline else { return }
                    let displayItems: [InlineCandidateDisplayItem] = {
                        if !pipeline.rankedCandidates.isEmpty {
                            return pipeline.rankedCandidates.map { c in
                                let text = c.fullText ?? c.displayText
                                return InlineCandidateDisplayItem(text: text, isAI: c.typedSource.isAI, summary: c.summary)
                            }
                        } else {
                            return pipeline.ranked.map { item in
                                let text = item.1.fullText ?? item.1.displayText
                                let isAI = item.0 == "llm" || item.0 == "generative"
                                return InlineCandidateDisplayItem(text: text, isAI: isAI)
                            }
                        }
                    }()
                    self.showCandidateList(items: displayItems, selectedIndex: engagement.selectedIndex)
                    self.currentMetrics.markCandidateProduced()
                }
            }
            pipeline.onRequestingChanged = { [weak self] isReq in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if isReq {
                        let hasPipelineGhost = !(self.inlinePipeline?.suggestion?.displayText.isEmpty ?? true)
                        if !hasPipelineGhost {
                            self.showWaiting()
                        }
                    }
                }
            }
        }

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

        // MARK: - Inline Completion (pipeline only)

        var ghostOverlay: InlineGhostOverlay?
        /// Warp-style candidate popup above the cursor (↑/↓ navigation).
        var candidateListOverlay: InlineCandidateListOverlay?
        // Ghost updates coalesced to display tick — LLM streams many deltas per frame.
        nonisolated(unsafe) var ghostCoalesceTask: Task<Void, Never>?
        private nonisolated(unsafe) var resignObserver: NSObjectProtocol?
        nonisolated(unsafe) var rightClickMonitor: Any?
        var currentMetrics = InlineMetrics()

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
                    self.inlinePipeline?.cancel()
                    self.hideGhost(reason: "window-nil")
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
                    guard let self else { return }
                    let hasPipeline = (self.inlinePipeline?.isRequesting ?? false) || self.inlinePipeline?.suggestion != nil
                    guard hasPipeline else { return }
                    if self.window?.isKeyWindow == true, self.window?.firstResponder === self {
                        if let s = self.inlinePipeline?.suggestion {
                            self.showGhost(text: s.displayText)
                        }
                    } else {
                        self.hideGhost(reason: "resign")
                    }
                }
            }
            installRightClickPasteMonitor()
        }

        deinit {
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
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let characters = event.characters

            let isFocused = MainActor.assumeIsolated { window?.firstResponder === self }
            guard isFocused else { return event }

            let shortcut = !ShortcutManager.isRecording ? MainActor.assumeIsolated({
                shortcutNotification(for: keyCode, modifiers: modifiers)
            }) : nil

            let isSearchActive = MainActor.assumeIsolated { TerminalSearchState.isActive }

            let (hasSuggestion, candidateCount, popupEnabled, engagement) = MainActor.assumeIsolated {
                let sug = self.inlinePipeline?.suggestion != nil
                let count = self.inlinePipeline?.ranked.count ?? 0
                let enabled = UserDefaults.standard.object(forKey: "ai_inline_candidate_popup") as? Bool ?? true
                let eng = self.inlinePipeline?.engagement ?? .passive
                return (sug, count, enabled, eng)
            }

            let (isNextCandidate, isPrevCandidate) = !ShortcutManager.isRecording ? MainActor.assumeIsolated({
                (
                    self.matchesAction(.inlineNextCandidate, keyCode: keyCode, modifiers: modifiers),
                    self.matchesAction(.inlinePreviousCandidate, keyCode: keyCode, modifiers: modifiers)
                )
            }) : (false, false)

            let decision = InlineKeyboardRouter.route(
                keyCode: keyCode,
                modifiers: modifiers,
                characters: characters,
                hasSuggestion: hasSuggestion,
                engagement: engagement,
                candidateCount: candidateCount,
                isPopupEnabled: popupEnabled,
                isSearchActive: isSearchActive,
                shortcutNotification: shortcut,
                isNextCandidate: isNextCandidate,
                isPreviousCandidate: isPrevCandidate
            )

            switch decision {
            case .interceptAppShortcut(let name):
                NotificationCenter.default.post(name: name, object: nil)
                return nil
            case .toggleSearch:
                NotificationCenter.default.post(name: .toggleTerminalSearch, object: nil)
                return nil
            case .accept:
                acceptSuggestion()
                return nil
            case .reject:
                MainActor.assumeIsolated {
                    self.pendingCompletionTask?.cancel()
                    self.pendingCompletionTask = nil
                    self.inlinePipeline?.rejectCurrent()
                    self.hideGhost(reason: "esc")
                }
                return nil
            case .moveSelection(let delta):
                MainActor.assumeIsolated { self.inlinePipeline?.moveSelection(delta) }
                return nil
            case .engageSelection(let initialIndex):
                MainActor.assumeIsolated {
                    self.inlinePipeline?.selectIndex(initialIndex)
                }
                return nil
            case .passthroughAndCancelSuggestion(let reason):
                MainActor.assumeIsolated {
                    self.pendingCompletionTask?.cancel()
                    self.pendingCompletionTask = nil
                    self.inlinePipeline?.cancel()
                    self.hideGhost(reason: reason)
                }
                return event
            case .passthroughAndSchedule:
                MainActor.assumeIsolated {
                    self.inlinePipeline?.resetEngagement()
                    self.inlinePipeline?.cancel()
                    self.hideGhost(reason: "new-typing")
                    self.scheduleCompletion()
                }
                return event
            case .passthrough:
                return event
            case .consume:
                return nil
            }
        }

        private func matchesAction(
            _ action: ShortcutAction,
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags
        ) -> Bool {
            guard let equivalent = ShortcutManager.shared.keyEquivalent(for: action) else { return false }
            return equivalent.keyCode == keyCode &&
                   equivalent.modifiers.nsModifierFlags.intersection([.command, .control, .option, .shift]) == modifiers
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
            case .nextTab, .previousTab, .settings, .inlineNextCandidate, .inlinePreviousCandidate: nil
            }
        }


        // MARK: - Completion Flow

        private func scheduleCompletion() {
            pendingCompletionTask?.cancel()
            currentMetrics = InlineMetrics(keyPressedAt: Date())
            pendingCompletionTask = Task { @MainActor [weak self] in
                // Allow SwiftTerm keyDown to finish and update inputBuffer / line state
                // 200ms debounce avoids frantic layout thrashing during fast continuous typing
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }
                self.requestCompletion()
            }
        }

        @MainActor
        private func requestCompletion() {
            // Single Intelligence entry: CommandContextSnapshot → InlinePipeline
            guard let pipeline = inlinePipeline, let snapshotProvider = commandSnapshotProvider else { return }
            // Keep isEnabled gate (legacy check via UserDefaults, now via pipeline's provider will also check, but keep early gate)
            guard UserDefaults.standard.bool(forKey: "ai_enabled"), UserDefaults.standard.bool(forKey: "ai_inline_suggestions") else { return }
            guard !terminal.isCurrentBufferAlternate else { return }
            let (cursorX, cursorY) = terminal.getCursorLocation()
            let yDisp = terminal.getTopVisibleRow()
            guard cursorY >= 0, cursorY < terminal.rows,
                  let line = terminal.getLine(row: cursorY) else { return }
            let isPromptRow: Bool? = {
                if let kind = terminal.semanticRowKind(at: yDisp + cursorY) {
                    return kind == .initial || kind == .continuation
                }
                return nil
            }()
            let lineLen = line.getTrimmedLength()
            guard CommandEditor.isCompletable(cursorX: cursorX, cursorY: cursorY, rows: terminal.rows, yDisp: yDisp, scrollPosition: scrollPosition, isAlternate: terminal.isCurrentBufferAlternate, lineTrimmedLength: lineLen, isPromptRow: isPromptRow) else { return }
            let base = snapshotProvider()
            let raw = line.translateToString(trimRight: true)
            guard let typedSnap = CommandEditor.typedSnapshot(base: base, rawLine: raw) else { return }
            pipeline.request(snapshot: typedSnap)
        }

        /// Pick the command text to complete: prefer the pure typed buffer when it
        /// is really the tail of the visible line, else fall back to prompt stripping.
        @available(*, deprecated, message: "Use CommandEditor.resolveTypedText")
        private func resolveTypedText(raw: String, inputBuffer: String) -> String? {
            let typed = inputBuffer.trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty, raw.hasSuffix(typed) { return typed }
            return SuggestionFormatter.commandText(from: raw)
        }

        /// Accept the current suggestion: send its text through the normal input
        /// path (history recording and broadcast included), then clear it.
        private nonisolated func acceptSuggestion() {
            MainActor.assumeIsolated {
                guard let p = self.inlinePipeline, p.suggestion != nil else { return }
                let text = p.accept()
                self.hideGhost(reason: "accept")
                // Re-align against the current line before inserting: the
                // suggestion may be stale (generated for an earlier typed
                // prefix mid-LLM-stream). Never duplicate what the user typed.
                let payloadText: String
                let (_, cursorY) = self.terminal.getCursorLocation()
                if cursorY >= 0, cursorY < self.terminal.rows,
                   let line = self.terminal.getLine(row: cursorY) {
                    let raw = line.translateToString(trimRight: true)
                    payloadText = CommandEditor.alignedAcceptSuffix(suggestion: text, rawLine: raw) ?? ""
                } else {
                    payloadText = text
                }
                guard !payloadText.isEmpty else { return }
                // Respect bracketed paste mode when inserting accepted ghost text (bypass for replacement backspaces)
                let payload: String
                if self.terminal.bracketedPasteMode && !payloadText.contains("\u{7F}") {
                    payload = "\u{1B}[200~" + payloadText + "\u{1B}[201~"
                } else {
                    payload = payloadText
                }
                let bytes = ArraySlice(payload.utf8)
                // Same forwarding as SwiftTerm's internal send — goes through
                // onSend → SessionManager → InputHandler (history preserved).
                terminalDelegate?.send(source: self, data: bytes)
            }
        }

        @MainActor
        func acceptCandidate(at index: Int) {
            guard let p = inlinePipeline else { return }
            let current = p.selectedIndex ?? 0
            p.moveSelection(index - current)
            acceptSuggestion()
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
