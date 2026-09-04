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

    var textColor: NSColor = NSColor.textColor.withAlphaComponent(0.48) {
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

/// Warp-style candidate list drawn near the cursor: ↑/↓ moves the selection,
/// Tab accepts the selected row. Frosted translucent panel, layer-backed,
/// clear text, selection highlight and keyboard hint footer.
final class InlineCandidateListOverlay: NSView {
    /// Hard cap of visible rows — keeps the panel compact and redraws cheap.
    static let maxVisibleRows = 5
    static let footerHeight: CGFloat = 20

    var items: [String] = [] {
        didSet {
            let capped = Array(items.prefix(Self.maxVisibleRows))
            guard capped != itemsCache else { return }
            itemsCache = capped
            cachedWidth = capped
                .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            contentView.needsDisplay = true
        }
    }
    private var itemsCache: [String] = []
    private var cachedWidth: CGFloat = 0

    var selectedIndex: Int? = nil {
        didSet {
            guard selectedIndex != oldValue else { return }
            contentView.needsDisplay = true
        }
    }

    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet {
            guard font != oldValue else { return }
            cachedWidth = itemsCache
                .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            contentView.needsDisplay = true
        }
    }

    var rowHeight: CGFloat = 22 {
        didSet {
            guard rowHeight != oldValue else { return }
            contentView.needsDisplay = true
        }
    }

    private let effectView = NSVisualEffectView()
    private lazy var contentView = CandidateContentView(owner: self)

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
        layer?.cornerRadius = 8
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        layer?.borderWidth = 1

        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 8
        effectView.layer?.masksToBounds = true
        effectView.material = .popover
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        addSubview(effectView)

        contentView.wantsLayer = true
        addSubview(contentView)
    }

    override var isFlipped: Bool {
        true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        effectView.frame = bounds
        contentView.frame = bounds
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        effectView.frame = bounds
        contentView.frame = bounds
    }

    func measuredWidth() -> CGFloat {
        max(180, cachedWidth + 36)
    }

    func totalHeight() -> CGFloat {
        guard !itemsCache.isEmpty, rowHeight > 0 else { return 0 }
        return CGFloat(itemsCache.count) * rowHeight + Self.footerHeight + 8
    }

    var visibleRowCount: Int {
        itemsCache.count
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    fileprivate final class CandidateContentView: NSView {
        weak var owner: InlineCandidateListOverlay?

        init(owner: InlineCandidateListOverlay) {
            self.owner = owner
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        override func draw(_: NSRect) {
            guard let owner, !owner.itemsCache.isEmpty, owner.rowHeight > 0 else { return }

            let iconFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
            let iconColor = NSColor.controlAccentColor
            let paddingY: CGFloat = 4
            let paddingX: CGFloat = 6

            for (index, item) in owner.itemsCache.enumerated() {
                let rowRect = NSRect(
                    x: paddingX,
                    y: paddingY + CGFloat(index) * owner.rowHeight,
                    width: bounds.width - paddingX * 2,
                    height: owner.rowHeight
                )

                let isSelected = owner.selectedIndex != nil && index == owner.selectedIndex
                if isSelected {
                    let path = NSBezierPath(roundedRect: rowRect, xRadius: 5, yRadius: 5)
                    NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
                    path.fill()
                }

                // AI Sparkle indicator
                let iconRect = NSRect(x: rowRect.minX + 6, y: rowRect.midY - 6, width: 12, height: 12)
                ("✦" as NSString).draw(
                    in: iconRect,
                    withAttributes: [
                        .font: iconFont,
                        .foregroundColor: isSelected ? iconColor : NSColor.tertiaryLabelColor
                    ]
                )

                let textColor: NSColor = isSelected ? .labelColor : .secondaryLabelColor
                let textRect = NSRect(
                    x: rowRect.minX + 22,
                    y: rowRect.origin.y + (owner.rowHeight - (owner.font.pointSize + 4)) / 2,
                    width: rowRect.width - 26,
                    height: owner.rowHeight
                )
                (item as NSString).draw(
                    in: textRect,
                    withAttributes: [
                        .font: owner.font,
                        .foregroundColor: textColor,
                    ]
                )
            }

            // Footer separator & hint
            let footerY = bounds.height - InlineCandidateListOverlay.footerHeight
            NSColor.separatorColor.withAlphaComponent(0.2).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: paddingX, y: footerY))
            line.line(to: NSPoint(x: bounds.width - paddingX, y: footerY))
            line.lineWidth = 0.5
            line.stroke()

            let footerFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)
            let footerText = (owner.selectedIndex != nil ? "↵ / ⇥ 补全   ↑↓ 选择   Esc 取消" : "⇥ 补全   ↑↓ 选择   ↵ 执行") as NSString
            let footerRect = NSRect(
                x: paddingX + 4,
                y: footerY + 3,
                width: bounds.width - paddingX * 2,
                height: 14
            )
            footerText.draw(
                in: footerRect,
                withAttributes: [
                    .font: footerFont,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            )
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }
}
