//
//  SearchHighlightOverlay.swift
//  Bonk
//
//  Independent search highlight overlay for TerminalView.
//  Optimized for production use with background thread calculation.
//

#if os(macOS)
import AppKit
import SwiftTerm

/// Overlay view that draws search highlights on top of TerminalView.
final class SearchHighlightOverlay: NSView {
    // MARK: - Types

    /// Structured match result for better performance
    struct MatchResult {
        let row: Int      // Viewport relative row
        let col: Int      // Start column
        let length: Int   // Column width (accounting for full-width chars)
    }

    // MARK: - Properties

    private var allMatches: [MatchResult] = []
    private var currentMatchIndex: Int = -1
    private weak var terminalView: TerminalView?

    private var cellWidth: CGFloat = 0
    private var cellHeight: CGFloat = 0

    // MARK: - Colors

    var allMatchesColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.3)
    var currentMatchColor: NSColor = NSColor.systemOrange.withAlphaComponent(0.6)

    // MARK: - Initialization

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: terminalView.bounds)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.autoresizingMask = [.width, .height]

        // Listen for resize events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: terminalView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Core fix 1: Force flip macOS Y-axis
    override var isFlipped: Bool { return true }

    // MARK: - Public API

    /// Update matches with pre-calculated data (called from background thread)
    @MainActor
    func updateMatches(_ matches: [MatchResult], currentMatchIndex: Int) {
        guard let terminalView = terminalView, let terminal = terminalView.terminal else { return }
        self.allMatches = matches
        self.currentMatchIndex = currentMatchIndex

        let cols = terminal.cols
        let rows = terminal.rows
        if cols > 0 && rows > 0 {
            self.cellWidth = terminalView.bounds.width / CGFloat(cols)
            self.cellHeight = terminalView.bounds.height / CGFloat(rows)
        }

        self.needsDisplay = true
    }

    /// Update current match index without recalculating matches
    func updateCurrentMatchIndex(_ index: Int) {
        self.currentMatchIndex = index
        needsDisplay = true
    }

    /// Clear all highlights
    func clearHighlights() {
        allMatches.removeAll()
        currentMatchIndex = -1
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, !allMatches.isEmpty else { return }

        // Performance: Only draw matches that intersect with dirtyRect
        for (index, match) in allMatches.enumerated() {
            let rect = CGRect(
                x: CGFloat(match.col) * cellWidth,
                y: CGFloat(match.row) * cellHeight,
                width: CGFloat(match.length) * cellWidth,
                height: cellHeight
            )

            guard rect.intersects(dirtyRect) else { continue }

            context.setFillColor(index == currentMatchIndex ? currentMatchColor.cgColor : allMatchesColor.cgColor)
            context.fill(rect)
        }
    }

    // MARK: - Private

    @objc private func frameDidChange() {
        guard let terminalView = terminalView, let terminal = terminalView.terminal else { return }
        let cols = terminal.cols
        let rows = terminal.rows
        if cols > 0 && rows > 0 {
            self.cellWidth = terminalView.bounds.width / CGFloat(cols)
            self.cellHeight = terminalView.bounds.height / CGFloat(rows)
        }
        needsDisplay = true
    }
}

// MARK: - Terminal Column Width Calculation

/// Calculate terminal column width for a string (handles CJK and Emoji)
func calculateTerminalColumns(for text: String) -> Int {
    var cols = 0
    for scalar in text.unicodeScalars {
        // CJK characters (Chinese, Japanese, Korean) occupy 2 columns
        if isCJKCharacter(scalar) {
            cols += 2
        } else {
            cols += 1
        }
    }
    return cols
}

/// Check if a Unicode scalar is a CJK character
private func isCJKCharacter(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    // CJK Unified Ideographs
    if value >= 0x4E00 && value <= 0x9FFF { return true }
    // CJK Unified Ideographs Extension A
    if value >= 0x3400 && value <= 0x4DBF { return true }
    // CJK Compatibility Ideographs
    if value >= 0xF900 && value <= 0xFAFF { return true }
    // CJK Radicals Supplement
    if value >= 0x2E80 && value <= 0x2EFF { return true }
    // Kangxi Radicals
    if value >= 0x2F00 && value <= 0x2FDF { return true }
    // CJK Symbols and Punctuation
    if value >= 0x3000 && value <= 0x303F { return true }
    // Hiragana
    if value >= 0x3040 && value <= 0x309F { return true }
    // Katakana
    if value >= 0x30A0 && value <= 0x30FF { return true }
    // Hangul Jamo
    if value >= 0x1100 && value <= 0x11FF { return true }
    // Hangul Syllables
    if value >= 0xAC00 && value <= 0xD7AF { return true }
    // Emoji (common ranges)
    if value >= 0x1F600 && value <= 0x1F64F { return true } // Emoticons
    if value >= 0x1F300 && value <= 0x1F5FF { return true } // Misc Symbols and Pictographs
    if value >= 0x1F680 && value <= 0x1F6FF { return true } // Transport and Map
    if value >= 0x1F1E0 && value <= 0x1F1FF { return true } // Flags
    return false
}
#endif
