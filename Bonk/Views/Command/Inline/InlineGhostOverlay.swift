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

import SwiftUI

// MARK: - Native Popover Bubble Shape & View (1:1 with AI Assistant Mode Menu)

struct InlineCandidateDisplayItem: Sendable, Equatable {
    let text: String
    let isAI: Bool
    let summary: String?

    init(text: String, isAI: Bool = false) {
        self.text = text
        self.isAI = isAI
        self.summary = nil
    }

    init(text: String, isAI: Bool, summary: String?) {
        self.text = text
        self.isAI = isAI
        self.summary = summary
    }
}

struct NativeVisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct CandidateBubbleShape: Shape {
    var arrowEdge: Edge = .top
    var arrowTipX: CGFloat = 24
    let arrowHeight: CGFloat = 8
    let arrowWidth: CGFloat = 18
    let cornerRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        guard w > 0, h > 0 else { return path }
        let r = cornerRadius
        let ah = arrowHeight
        let halfAw = arrowWidth / 2
        let clampedTipX = max(r + halfAw + 2, min(w - r - halfAw - 2, arrowTipX))

        if arrowEdge == .top {
            let bodyTop = ah
            let bodyBottom = h

            // Start on top edge just to the right of the arrow
            path.move(to: CGPoint(x: clampedTipX + halfAw, y: bodyTop))

            // Top edge to top-right corner
            path.addLine(to: CGPoint(x: w - r, y: bodyTop))
            path.addArc(tangent1End: CGPoint(x: w, y: bodyTop), tangent2End: CGPoint(x: w, y: bodyBottom), radius: r)

            // Right edge to bottom-right corner
            path.addLine(to: CGPoint(x: w, y: bodyBottom - r))
            path.addArc(tangent1End: CGPoint(x: w, y: bodyBottom), tangent2End: CGPoint(x: 0, y: bodyBottom), radius: r)

            // Bottom edge to bottom-left corner
            path.addLine(to: CGPoint(x: r, y: bodyBottom))
            path.addArc(tangent1End: CGPoint(x: 0, y: bodyBottom), tangent2End: CGPoint(x: 0, y: bodyTop), radius: r)

            // Left edge to top-left corner
            path.addLine(to: CGPoint(x: 0, y: bodyTop + r))
            path.addArc(tangent1End: CGPoint(x: 0, y: bodyTop), tangent2End: CGPoint(x: clampedTipX - halfAw, y: bodyTop), radius: r)

            // Top edge to left base of arrow
            path.addLine(to: CGPoint(x: clampedTipX - halfAw, y: bodyTop))

            // Smooth upward curve from left base into arrow (concave fillet)
            path.addCurve(
                to: CGPoint(x: clampedTipX - 2.8, y: 1.5),
                control1: CGPoint(x: clampedTipX - halfAw + 3.5, y: bodyTop),
                control2: CGPoint(x: clampedTipX - 4.8, y: 4.0)
            )

            // Smooth rounded apex over the tip (convex cap)
            path.addCurve(
                to: CGPoint(x: clampedTipX + 2.8, y: 1.5),
                control1: CGPoint(x: clampedTipX - 1.2, y: 0.0),
                control2: CGPoint(x: clampedTipX + 1.2, y: 0.0)
            )

            // Smooth downward curve from arrow into right base (concave fillet)
            path.addCurve(
                to: CGPoint(x: clampedTipX + halfAw, y: bodyTop),
                control1: CGPoint(x: clampedTipX + 4.8, y: 4.0),
                control2: CGPoint(x: clampedTipX + halfAw - 3.5, y: bodyTop)
            )

            path.closeSubpath()
        } else {
            let bodyTop: CGFloat = 0
            let bodyBottom = h - ah

            // Start on top edge at top-left corner
            path.move(to: CGPoint(x: r, y: bodyTop))

            // Top edge to top-right corner
            path.addLine(to: CGPoint(x: w - r, y: bodyTop))
            path.addArc(tangent1End: CGPoint(x: w, y: bodyTop), tangent2End: CGPoint(x: w, y: bodyBottom), radius: r)

            // Right edge to bottom-right corner
            path.addLine(to: CGPoint(x: w, y: bodyBottom - r))
            path.addArc(tangent1End: CGPoint(x: w, y: bodyBottom), tangent2End: CGPoint(x: clampedTipX + halfAw, y: bodyBottom), radius: r)

            // Bottom edge to right base of arrow
            path.addLine(to: CGPoint(x: clampedTipX + halfAw, y: bodyBottom))

            // Smooth downward curve from right base into arrow (concave fillet)
            path.addCurve(
                to: CGPoint(x: clampedTipX + 2.8, y: h - 1.5),
                control1: CGPoint(x: clampedTipX + halfAw - 3.5, y: bodyBottom),
                control2: CGPoint(x: clampedTipX + 4.8, y: h - 4.0)
            )

            // Smooth rounded apex at the bottom tip (convex cap)
            path.addCurve(
                to: CGPoint(x: clampedTipX - 2.8, y: h - 1.5),
                control1: CGPoint(x: clampedTipX + 1.2, y: h),
                control2: CGPoint(x: clampedTipX - 1.2, y: h)
            )

            // Smooth upward curve from arrow into left base (concave fillet)
            path.addCurve(
                to: CGPoint(x: clampedTipX - halfAw, y: bodyBottom),
                control1: CGPoint(x: clampedTipX - 4.8, y: h - 4.0),
                control2: CGPoint(x: clampedTipX - halfAw + 3.5, y: bodyBottom)
            )

            // Bottom edge to bottom-left corner
            path.addLine(to: CGPoint(x: r, y: bodyBottom))
            path.addArc(tangent1End: CGPoint(x: 0, y: bodyBottom), tangent2End: CGPoint(x: 0, y: bodyTop), radius: r)

            // Left edge to top-left corner
            path.addLine(to: CGPoint(x: 0, y: bodyTop + r))
            path.addArc(tangent1End: CGPoint(x: 0, y: bodyTop), tangent2End: CGPoint(x: r, y: bodyTop), radius: r)

            path.closeSubpath()
        }
        return path
    }
}

struct CandidateBubbleView: View {
    let items: [InlineCandidateDisplayItem]
    let selectedIndex: Int?
    let arrowEdge: Edge
    let arrowTipX: CGFloat
    let onSelect: (Int) -> Void

    var body: some View {
        let shape = CandidateBubbleShape(arrowEdge: arrowEdge, arrowTipX: arrowTipX)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let isSelected = (selectedIndex ?? 0) == index
                Button {
                    onSelect(index)
                } label: {
                    HStack(spacing: 8) {
                        Text(item.text)
                            .font(.system(size: 12, weight: isSelected ? .medium : .regular, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if item.isAI {
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 9, weight: .bold))
                                Text("AI")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, arrowEdge == .top ? 12 : 4)
        .padding(.bottom, arrowEdge == .bottom ? 12 : 4)
        .background(
            ZStack {
                NativeVisualEffectBlur(material: .popover, blendingMode: .withinWindow)
                Color(nsColor: .windowBackgroundColor).opacity(0.25)
            }
            .clipShape(shape)
        )
        .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
        .shadow(color: Color.black.opacity(0.20), radius: 12, x: 0, y: 5)
    }
}

fileprivate final class NonFocusHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }
}

/// Warp-style candidate list drawn near the cursor: ↑/↓ moves the selection,
/// Tab accepts the selected row. Genuine native Popover bubble with arrow pointer,
/// pure translucent frosted glass, subtle border, shadow, and 1:1 styling with AI assistant popover.
final class InlineCandidateListOverlay: NSView {
    /// Hard cap of visible rows — keeps the panel compact and redraws cheap.
    static let maxVisibleRows = 5

    enum ArrowEdge: Sendable, Equatable {
        case top    // Bubble is below cursor; arrow points up at cursor
        case bottom // Bubble is above cursor; arrow points down at cursor
        var swiftUIEdge: Edge { self == .top ? .top : .bottom }
    }

    var onSelect: ((Int) -> Void)?

    var arrowEdge: ArrowEdge = .top {
        didSet {
            guard arrowEdge != oldValue else { return }
            updateContent()
        }
    }

    var arrowTipX: CGFloat = 24 {
        didSet {
            guard arrowTipX != oldValue else { return }
            updateContent()
        }
    }

    let arrowHeight: CGFloat = 8
    let arrowWidth: CGFloat = 18
    let cornerRadius: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    var displayItems: [InlineCandidateDisplayItem] = [] {
        didSet {
            displayItemsCache = Array(displayItems.prefix(Self.maxVisibleRows))
            updateContent()
        }
    }
    private var displayItemsCache: [InlineCandidateDisplayItem] = []

    var items: [String] {
        get { displayItemsCache.map(\.text) }
        set {
            displayItems = newValue.map { InlineCandidateDisplayItem(text: $0, isAI: false) }
        }
    }

    var selectedIndex: Int? = nil {
        didSet {
            guard selectedIndex != oldValue else { return }
            updateContent()
        }
    }

    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var rowHeight: CGFloat = 24

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private var hostingView: NonFocusHostingView<CandidateBubbleView>?

    private func updateContent() {
        guard !displayItemsCache.isEmpty else {
            hostingView?.isHidden = true
            return
        }
        let bubble = CandidateBubbleView(
            items: displayItemsCache,
            selectedIndex: selectedIndex,
            arrowEdge: arrowEdge.swiftUIEdge,
            arrowTipX: arrowTipX,
            onSelect: { [weak self] idx in self?.onSelect?(idx) }
        )
        if let hostingView {
            hostingView.rootView = bubble
            hostingView.isHidden = false
        } else {
            let h = NonFocusHostingView(rootView: bubble)
            h.wantsLayer = true
            h.layer?.backgroundColor = NSColor.clear.cgColor
            addSubview(h)
            hostingView = h
        }
        hostingView?.frame = bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        hostingView?.frame = bounds
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        hostingView?.frame = bounds
    }

    func measuredWidth() -> CGFloat {
        guard !displayItemsCache.isEmpty else { return 0 }
        let textWidth = displayItemsCache.map { item -> CGFloat in
            (item.text as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return max(180, min(380, textWidth + 56))
    }

    func totalHeight() -> CGFloat {
        guard !displayItemsCache.isEmpty else { return 0 }
        let count = CGFloat(displayItemsCache.count)
        let spacing = CGFloat(max(0, displayItemsCache.count - 1)) * 2
        return (count * rowHeight) + spacing + 16
    }

    var visibleRowCount: Int {
        displayItemsCache.count
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        return super.hitTest(point)
    }
}
