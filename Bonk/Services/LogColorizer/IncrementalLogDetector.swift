//
//  IncrementalLogDetector.swift
//  Bonk — Final Architecture: Terminal Grid + Incremental Log Detection
//
//  Only processes new/changed rows from Terminal Grid.
//  Never re-scans the entire buffer.
//

import Foundation

@MainActor
final class IncrementalLogDetector {
    private var lastProcessedRow: Int = -1
    private let classifier = LogClassifier()
    private let scanner = ZeroCopyScanner()
    private let cache = LazyHighlightCache()
    private let overlay = HighlightOverlay.shared

    /// Called when Terminal Grid has new rows (after feed).
    /// `newRows` are the logical rows that were appended/changed (incremental).
    func didUpdateRows(_ rows: [String], baseRow: Int) {
        // Degraded mode: if flood >50k lines/sec, reduce or disable
        if DegradedMode.shared.shouldDropLogHighlight(lineCount: rows.count) {
            return // Terminal rendering stays priority
        }
        for (offset, line) in rows.enumerated() {
            let row = baseRow + offset
            // Classifier is the gate: NOT_LOG -> no highlight, LOG -> scanner
            let cls = classifier.classify(line)
            guard cls == .log || cls == .continuation else {
                overlay.clear(row: row)
                continue
            }
            // Zero-copy scanner on confirmed log only
            let spans = scanner.scan(line: line)
            if spans.isEmpty {
                overlay.clear(row: row)
            } else {
                cache.store(row: row, line: line, spans: spans)
                overlay.set(row: row, spans: spans)
            }
        }
        lastProcessedRow = baseRow + rows.count - 1
    }

    func viewportChanged(visibleRows: Range<Int>) {
        // Lazy: only ensure visible rows are highlighted, use cache
        for row in visibleRows {
            if let entry = cache.get(row: row) {
                overlay.set(row: row, spans: entry.spans)
            }
        }
    }

    func clearAll() {
        cache.clear()
        overlay.clearAll()
        classifier.reset()
        lastProcessedRow = -1
    }
}
