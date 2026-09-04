import AppKit
import os
import SwiftTerm

extension NativeTerminalView {
    private static let inlineLogger = Logger(subsystem: "com.bonk", category: "InlineGhost")

    // MARK: - Ghost Overlay

    func ensureGhostOverlay() -> InlineGhostOverlay {
        if let ghostOverlay { return ghostOverlay }
        let overlay = InlineGhostOverlay()
        overlay.font = font
        addSubview(overlay, positioned: .above, relativeTo: nil)
        ghostOverlay = overlay
        return overlay
    }

    // MARK: - Persistent Candidate List Overlay (N=1)

    func ensureCandidateListOverlay() -> InlineCandidateListOverlay {
        if let candidateListOverlay { return candidateListOverlay }
        let overlay = InlineCandidateListOverlay()
        overlay.font = font
        overlay.isHidden = true
        overlay.onSelect = { [weak self] index in
            self?.acceptCandidate(at: index)
        }
        addSubview(overlay, positioned: .above, relativeTo: nil)
        candidateListOverlay = overlay
        return overlay
    }

    /// Row height derived from font metrics, 2pt vertical padding per side.
    static func candidateRowHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 4
    }

    @MainActor
    func showCandidateList(items: [String], selectedIndex: Int?) {
        let enabled = UserDefaults.standard.object(forKey: "ai_inline_candidate_popup") as? Bool ?? true
        guard enabled else {
            hideCandidateList()
            return
        }
        guard window?.firstResponder === self else { return }
        guard items.count > 1 else {
            hideCandidateList()
            return
        }
        let overlay = ensureCandidateListOverlay()
        overlay.font = font
        overlay.rowHeight = Self.candidateRowHeight(for: font)
        overlay.items = items
        overlay.selectedIndex = selectedIndex
        overlay.isHidden = false
        positionCandidateListOverlay()
    }

    @MainActor
    func hideCandidateList() {
        candidateListOverlay?.isHidden = true
        candidateListOverlay?.items = []
    }

    // Ghost updates coalesced to display tick — LLM streams many deltas per frame, but overlay
    // should only commit once per frame (shared single presentation clock).
    private static let ghostCoalesceInterval: Duration = .milliseconds(16)

    @MainActor
    func showGhost(text: String) {
        Self.inlineLogger.debug("showGhost len=\(text.count, privacy: .public)")
        guard window?.firstResponder === self else { return }
        guard !text.isEmpty else {
            hideGhost(reason: "empty")
            return
        }
        let overlay = ensureGhostOverlay()
        overlay.font = font
        overlay.waiting = false
        if overlay.text == text { return }
        overlay.text = text
        overlay.isHidden = false
        scheduleGhostPositionCoalesced()
    }

    @MainActor
    func hideGhost(reason: String) {
        Self.inlineLogger.debug("hideGhost reason=\(reason, privacy: .public)")
        cancelGhostCoalesceIfNeeded()
        ghostOverlay?.isHidden = true
        ghostOverlay?.text = ""
        ghostOverlay?.waiting = false
        hideCandidateList()
    }

    /// Show the "thinking" dots while the model request is in flight.
    @MainActor
    func showWaiting() {
        guard window?.firstResponder === self else { return }
        let overlay = ensureGhostOverlay()
        overlay.font = font
        overlay.text = ""
        overlay.waiting = true
        overlay.isHidden = false
        scheduleGhostPositionCoalesced()
    }

    @MainActor
    private func scheduleGhostPositionCoalesced() {
        // Single clock: coalesce rapid LLM deltas to one frame, avoid MainActor thrash.
        if ghostCoalesceTask != nil { return }
        ghostCoalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.ghostCoalesceInterval)
            self?.ghostCoalesceTask = nil
            self?.positionGhostOverlay()
        }
    }

    @MainActor
    private func cancelGhostCoalesceIfNeeded() {
        ghostCoalesceTask?.cancel()
        ghostCoalesceTask = nil
    }

    /// Place the ghost text right after the terminal cursor.
    func positionGhostOverlay() {
        guard let overlay = ghostOverlay,
              !overlay.text.isEmpty || overlay.waiting
        else { return }
        let cell = Self.cellSize(for: font, backingScale: window?.backingScaleFactor ?? 2)
        let (cursorX, cursorY) = terminal.getCursorLocation()
        let yDisp = terminal.getTopVisibleRow()

        // Same bottom-of-buffer gate as requestCompletion: at the bottom the
        // cursor row equals the screen row; otherwise skip (off-screen).
        let atBottom = scrollPosition >= 1.0 || yDisp == 0
        let isFocused = window?.isKeyWindow == true && window?.firstResponder === self
        guard atBottom, isFocused, cursorY >= 0, cursorY < terminal.rows else {
            let position = self.scrollPosition
            let posLog = "hideGhost reason=offscreen pos=\(position) yDisp=\(yDisp)"
            Self.inlineLogger.debug("\(posLog, privacy: .public)")
            overlay.isHidden = true
            hideCandidateList()
            return
        }
        overlay.isHidden = false

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

        positionCandidateListOverlay()
    }

    /// Position the persistent candidate list overlay relative to the terminal cursor.
    func positionCandidateListOverlay() {
        guard let list = candidateListOverlay, !list.isHidden, list.visibleRowCount > 0, list.rowHeight > 0 else { return }
        let cell = Self.cellSize(for: font, backingScale: window?.backingScaleFactor ?? 2)
        let (cursorX, cursorY) = terminal.getCursorLocation()
        let originX = CGFloat(cursorX) * cell.width

        let listHeight = list.totalHeight()
        let listWidth = min(list.measuredWidth(), bounds.width - 16)
        let x = min(originX, max(8, bounds.width - listWidth - 8))
        let cursorRowBottom = bounds.height - CGFloat(cursorY + 1) * cell.height
        let cursorRowTop = bounds.height - CGFloat(cursorY) * cell.height

        var y = cursorRowBottom - listHeight - 4
        if y < 4 {
            y = cursorRowTop + 4
            if y + listHeight > bounds.height - 4 {
                y = max(4, bounds.height - listHeight - 4)
            }
        }
        list.frame = NSRect(x: x, y: y, width: listWidth, height: listHeight)
    }
}
