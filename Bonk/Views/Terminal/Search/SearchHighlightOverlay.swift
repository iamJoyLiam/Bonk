//
//  SearchHighlightOverlay.swift
//  Bonk
//
//  Independent search highlight overlay for TerminalView.
//  Does not depend on SwiftTerm's Selection rendering chain.
//

#if os(macOS)
import AppKit
import SwiftTerm

/// Overlay view that draws search highlights on top of TerminalView.
final class SearchHighlightOverlay: NSView {
    // MARK: - Properties

    /// All match positions (row, col, length)
    private var allMatches: [(row: Int, col: Int, length: Int)] = []

    /// Current match index
    private var currentMatchIndex: Int = -1

    /// Reference to the terminal view for coordinate conversion
    private weak var terminalView: TerminalView?

    /// Cell dimensions for coordinate conversion
    private var cellWidth: CGFloat = 0
    private var cellHeight: CGFloat = 0

    // MARK: - Colors

    /// Color for all matches (semi-transparent yellow)
    var allMatchesColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.3)

    /// Color for current match (bright orange)
    var currentMatchColor: NSColor = NSColor.systemOrange.withAlphaComponent(0.6)

    // MARK: - Initialization

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: terminalView.bounds)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 核心修复 1: 强制翻转 macOS Y 轴，使原点对齐左上角
    override var isFlipped: Bool { return true }

    // MARK: - Public API

    /// Update search highlights
    func updateHighlights(
        searchText: String,
        terminal: Terminal,
        currentMatchIndex: Int
    ) {
        self.currentMatchIndex = currentMatchIndex

        guard let tv = terminalView else { return }
        let cols = terminal.cols
        let rows = terminal.rows

        // 核心修复 2: 计算单元格尺寸
        if cols > 0 && rows > 0 {
            self.cellWidth = tv.bounds.width / CGFloat(cols)
            self.cellHeight = tv.bounds.height / CGFloat(rows)
        }

        // 核心修复 3: 基于当前视口偏移量提取文本
        self.allMatches = findAllMatches(searchText: searchText, terminal: terminal)
        self.needsDisplay = true
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

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        for (index, match) in allMatches.enumerated() {
            let rect = rectForMatch(match)

            if index == currentMatchIndex {
                context.setFillColor(currentMatchColor.cgColor)
            } else {
                context.setFillColor(allMatchesColor.cgColor)
            }

            context.fill(rect)
        }
    }

    // MARK: - Private

    /// Find all matches in the terminal buffer
    private func findAllMatches(
        searchText: String,
        terminal: Terminal
    ) -> [(row: Int, col: Int, length: Int)] {
        var matches: [(row: Int, col: Int, length: Int)] = []
        let lowerSearch = searchText.lowercased()
        let cols = terminal.cols
        let rows = terminal.rows

        // 核心修复 3: 基于当前视口偏移量 (yDisp) 提取文本
        let yDisp = terminal.buffer.yDisp

        for visibleRow in 0..<rows {
            // 获取可视范围内的绝对行号
            let absoluteRow = yDisp + visibleRow

            // 按行提取并匹配
            let start = Position(col: 0, row: absoluteRow)
            let end = Position(col: cols - 1, row: absoluteRow)
            let lineText = terminal.getText(start: start, end: end).lowercased()

            var searchStart = lineText.startIndex
            while searchStart < lineText.endIndex,
                  let range = lineText[searchStart...].range(of: lowerSearch) {
                let colIndex = lineText.distance(from: lineText.startIndex, to: range.lowerBound)
                let matchLength = lineText.distance(from: range.lowerBound, to: range.upperBound)

                if colIndex < cols {
                    // 保存匹配结果，row 是 Viewport 的相对行号
                    matches.append((row: visibleRow, col: colIndex, length: min(matchLength, cols - colIndex)))
                }
                searchStart = range.upperBound
            }
        }

        return matches
    }

    /// Convert match position to view rect
    private func rectForMatch(_ match: (row: Int, col: Int, length: Int)) -> CGRect {
        // Y轴已被 isFlipped 修复，可以直接正常进行乘法计算
        return CGRect(
            x: CGFloat(match.col) * cellWidth,
            y: CGFloat(match.row) * cellHeight,
            width: CGFloat(match.length) * cellWidth,
            height: cellHeight
        )
    }
}
#endif
