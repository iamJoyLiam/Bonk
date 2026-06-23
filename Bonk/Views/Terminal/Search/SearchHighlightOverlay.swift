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
            let row: Int // Viewport relative row
            let col: Int // Start column
            let length: Int // Column width (accounting for full-width chars)
        }

        // MARK: - Properties

        private var allMatches: [MatchResult] = []
        private var currentMatchIndex: Int = -1
        private weak var terminalView: TerminalView?

        private var cellWidth: CGFloat = 0
        private var cellHeight: CGFloat = 0

        // MARK: - Colors

        var allMatchesColor: NSColor = .systemYellow.withAlphaComponent(0.3)
        var currentMatchColor: NSColor = .systemOrange.withAlphaComponent(0.6)

        // MARK: - Initialization

        init(terminalView: TerminalView) {
            self.terminalView = terminalView
            super.init(frame: terminalView.bounds)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            autoresizingMask = [.width, .height]

            // Listen for resize events
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(frameDidChange),
                name: NSView.frameDidChangeNotification,
                object: terminalView
            )
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Core fix 1: Force flip macOS Y-axis
        override var isFlipped: Bool {
            true
        }

        // MARK: - Public API

        /// Update matches with pre-calculated data (called from background thread)
        @MainActor
        func updateMatches(_ matches: [MatchResult], currentMatchIndex: Int) {
            guard let terminalView, let terminal = terminalView.terminal else { return }
            allMatches = matches
            self.currentMatchIndex = currentMatchIndex

            let cols = terminal.cols
            let rows = terminal.rows
            if cols > 0, rows > 0 {
                cellWidth = terminalView.bounds.width / CGFloat(cols)
                cellHeight = terminalView.bounds.height / CGFloat(rows)
            }

            needsDisplay = true
        }

        /// Update current match index without recalculating matches
        func updateCurrentMatchIndex(_ index: Int) {
            currentMatchIndex = index
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
            guard let terminalView, let terminal = terminalView.terminal else { return }
            let cols = terminal.cols
            let rows = terminal.rows
            if cols > 0, rows > 0 {
                cellWidth = terminalView.bounds.width / CGFloat(cols)
                cellHeight = terminalView.bounds.height / CGFloat(rows)
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

    /// CJK and Emoji Unicode ranges (characters that occupy 2 terminal columns)
    private let wideCharacterRanges: [ClosedRange<UInt32>] = [
        0x1100 ... 0x11FF, // Hangul Jamo
        0x2E80 ... 0x2EFF, // CJK Radicals Supplement
        0x2F00 ... 0x2FDF, // Kangxi Radicals
        0x3000 ... 0x303F, // CJK Symbols and Punctuation
        0x3040 ... 0x309F, // Hiragana
        0x30A0 ... 0x30FF, // Katakana
        0x3400 ... 0x4DBF, // CJK Unified Ideographs Extension A
        0x4E00 ... 0x9FFF, // CJK Unified Ideographs
        0xAC00 ... 0xD7AF, // Hangul Syllables
        0xF900 ... 0xFAFF, // CJK Compatibility Ideographs
        0x1F1E0 ... 0x1F1FF, // Flags
        0x1F300 ... 0x1F5FF, // Misc Symbols and Pictographs
        0x1F600 ... 0x1F64F, // Emoticons
        0x1F680 ... 0x1F6FF, // Transport and Map
    ]

    /// Check if a Unicode scalar is a wide character (CJK or Emoji)
    private func isCJKCharacter(_ scalar: Unicode.Scalar) -> Bool {
        wideCharacterRanges.contains { $0.contains(scalar.value) }
    }
#endif
