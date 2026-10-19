//
//  TerminalScreenRead.swift
//  Bonk
//
//  SwiftTerm 1.99 / 2.0 no longer exposes the mutable terminal. These reads
//  go through the view's copied snapshots.
//

import Foundation
import SwiftTerm

private enum ScrollbackAppliedKey {
    nonisolated(unsafe) static var key = 0
}

extension TerminalView {
    /// The alternate screen has no scrollback, so its thumb size is 0.
    /// A normal buffer's thumb is at least a small positive fraction.
    var isAlternateScreen: Bool { scrollThumbsize == CGFloat(0) }

    /// `changeScrollback` drops history, so it runs only when the length changes.
    /// 2.0 does not expose the current scrollback length to compare against.
    func applyScrollbackLines(_ lines: Int) {
        let applied = objc_getAssociatedObject(self, &ScrollbackAppliedKey.key) as? Int
        guard applied != lines else { return }
        objc_setAssociatedObject(self, &ScrollbackAppliedKey.key, lines, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        changeScrollback(lines)
    }

    /// Cursor column and row in the visible screen, plus that row's text.
    func screenCursorLine() -> (x: Int, y: Int, rows: Int, viewportRow: Int, line: String?) {
        let snapshot = terminalStateSnapshot()
        let row = snapshot.cursor.row
        let line = row >= 0 ? visibleRowsText(row..<(row + 1)).first : nil
        return (snapshot.cursor.col, row, snapshot.dimensions.rows, snapshot.viewportRow, line)
    }

    var bracketedPasteEnabled: Bool {
        terminalStateSnapshot().bracketedPasteMode
    }
}
