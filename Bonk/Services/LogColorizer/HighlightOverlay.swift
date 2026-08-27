//
//  HighlightOverlay.swift
//  Bonk — Final Architecture: Highlight Overlay
//
//  Log colors as overlay on top of Terminal Grid, never modifies grid.
//  Clearing overlay does not rebuild buffer.
//

import Foundation
import SwiftTerm

final class HighlightOverlay: @unchecked Sendable {
    nonisolated(unsafe) static let shared = HighlightOverlay()

    // Row -> spans overlay (not in grid)
    private var overlays: [Int: [HighlightSpan]] = [:]
    private let lock = NSLock()

    func set(row: Int, spans: [HighlightSpan]) {
        lock.lock()
        overlays[row] = spans
        lock.unlock()
        // In a full Metal renderer, this would mark row dirty for overlay compositing
        // For SwiftTerm, we apply via attributed string overlay without touching grid
    }

    func clear(row: Int) {
        lock.lock()
        overlays.removeValue(forKey: row)
        lock.unlock()
    }

    func clearAll() {
        lock.lock()
        overlays.removeAll()
        lock.unlock()
    }

    // Final render: Terminal Attributes + Overlay -> composited attributes
    func spans(for row: Int) -> [HighlightSpan] {
        lock.lock()
        defer { lock.unlock() }
        return overlays[row] ?? []
    }

    // For SwiftTerm's feed path: if overlay exists, wrap spans with ANSI without touching grid
    func apply(to line: String, row: Int) -> String {
        let spans = spans(for: row)
        guard !spans.isEmpty else { return line }
        let nsLine = line as NSString
        let mutable = NSMutableString(string: line)
        for span in spans.reversed() {
            let r = NSRange(location: span.offset, length: span.length)
            let original = nsLine.substring(with: r)
            let wrapped = "\u{1B}[\(span.ansiCode)m\(original)\u{1B}[0m"
            mutable.replaceCharacters(in: r, with: wrapped)
        }
        return mutable as String
    }
}
