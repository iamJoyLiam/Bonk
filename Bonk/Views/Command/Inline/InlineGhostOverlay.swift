//
//  InlineGhostOverlay.swift
//  Bonk
//
//  Ghost-text overlay rendered right after the terminal cursor, Warp-style.
//  Draws the pending AI suggestion in a muted color without intercepting events.
//

import AppKit

/// Lightweight non-interactive view that draws the inline completion
/// suggestion after the terminal cursor.
final class InlineGhostOverlay: NSView {
    /// Suggestion text. Setting it re-measures and redraws.
    var text: String = "" {
        didSet { needsDisplay = true }
    }

    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet { needsDisplay = true }
    }

    var textColor: NSColor = .tertiaryLabelColor {
        didSet { needsDisplay = true }
    }

    /// True while the model is thinking but nothing is suggested yet —
    /// draws a subtle pending indicator so the user knows a hint is coming.
    var waiting: Bool = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_: NSRect) {
        guard !text.isEmpty || waiting else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        if !text.isEmpty {
            (text as NSString).draw(at: .zero, withAttributes: attributes)
        } else {
            ("…" as NSString).draw(at: .zero, withAttributes: attributes)
        }
    }

    /// Width of the current suggestion text in points.
    func measuredWidth() -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
