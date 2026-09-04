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

/// Warp-style candidate list drawn above the cursor: ↑/↓ moves the selection,
/// Tab accepts the selected row. Native vibrancy panel (NSVisualEffectView),
/// layer-backed, capped rows, width measured only when content changes.
final class InlineCandidateListOverlay: NSView {
    /// Hard cap of visible rows — keeps the panel compact and redraws cheap.
    static let maxVisibleRows = 5

    var items: [String] = [] {
        didSet {
            let capped = Array(items.prefix(Self.maxVisibleRows))
            guard capped != itemsCache else { return }
            itemsCache = capped
            cachedWidth = capped
                .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            needsDisplay = true
        }
    }
    private var itemsCache: [String] = []
    private var cachedWidth: CGFloat = 0

    var selectedIndex = 0 {
        didSet {
            guard selectedIndex != oldValue else { return }
            needsDisplay = true
        }
    }

    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) {
        didSet {
            guard font != oldValue else { return }
            cachedWidth = itemsCache
                .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            needsDisplay = true
        }
    }

    /// Row height derived from font metrics — set by the presenter.
    var rowHeight: CGFloat = 0 {
        didSet {
            guard rowHeight != oldValue else { return }
            needsDisplay = true
        }
    }

    private let effectView = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        addSubview(effectView)
    }

    override var isFlipped: Bool {
        true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        effectView.frame = bounds
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        effectView.frame = bounds
    }

    override func draw(_: NSRect) {
        guard !itemsCache.isEmpty, rowHeight > 0 else { return }
        for (index, item) in itemsCache.enumerated() {
            let row = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
            if index == selectedIndex {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(rect: row).fill()
            }
            let color: NSColor = index == selectedIndex ? .labelColor : .secondaryLabelColor
            // 8pt horizontal inset keeps text off the panel edge.
            (item as NSString).draw(
                in: row.insetBy(dx: 8, dy: 0),
                withAttributes: [.font: font, .foregroundColor: color]
            )
        }
    }

    /// Widest row width in points (cached — measured only when items/font change).
    func measuredWidth() -> CGFloat {
        cachedWidth
    }

    var visibleRowCount: Int {
        itemsCache.count
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
