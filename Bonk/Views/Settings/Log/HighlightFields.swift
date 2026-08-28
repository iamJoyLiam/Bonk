import SwiftUI
import AppKit

// MARK: - HighlightTextView

final class HighlightTextView: NSTextView {
    var onChange: ((String) -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }
    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); needsDisplay = true; return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); needsDisplay = true; return r }
}

// MARK: - SingleLineHighlightField

struct SingleLineHighlightField: NSViewRepresentable {
    @Binding var text: String
    var pattern: String
    var color: Color

    private var compiled: NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = HighlightTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 22))
        tv.isEditable = true; tv.isSelectable = true; tv.drawsBackground = false
        tv.backgroundColor = .clear; tv.focusRingType = .none
        tv.isRichText = true; tv.allowsUndo = true; tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainer?.lineFragmentPadding = 2; tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.isHorizontallyResizable = false; tv.isVerticallyResizable = false
        tv.textContainer?.widthTracksTextView = true; tv.textContainer?.lineBreakMode = .byTruncatingTail
        tv.delegate = context.coordinator; tv.onChange = { text = $0 }
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 22))
        sv.hasVerticalScroller = false; sv.hasHorizontalScroller = false; sv.drawsBackground = false
        sv.backgroundColor = .clear; sv.borderType = .noBorder; sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? HighlightTextView else { return }
        let sel = tv.selectedRange()
        let isFirst = tv.window?.firstResponder == tv
        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: attr.length))
        if let re = compiled {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                attr.addAttribute(.foregroundColor, value: NSColor(color), range: m.range)
                attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), range: m.range)
            }
        }
        if tv.string != text || !(tv.textStorage?.isEqual(to: attr) ?? false) {
            tv.textStorage?.setAttributedString(attr)
            if sel.location != NSNotFound && sel.location <= attr.length { tv.setSelectedRange(sel) }
            if isFirst { tv.setSelectedRange(sel) }
        }
        tv.onChange = { text = $0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SingleLineHighlightField
        init(_ p: SingleLineHighlightField) { parent = p }
        func textDidChange(_ n: Notification) { guard let tv = n.object as? NSTextView else { return }; parent.text = tv.string }
    }
}

// MARK: - ProfileHighlightField

struct ProfileHighlightField: NSViewRepresentable {
    @Binding var text: String
    var profile: LogProfile

    func makeNSView(context: Context) -> NSScrollView {
        let tv = HighlightTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 84))
        tv.isEditable = true; tv.isSelectable = true; tv.drawsBackground = false
        tv.backgroundColor = .clear; tv.isRichText = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainer?.lineFragmentPadding = 2; tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.isHorizontallyResizable = false; tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true; tv.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineBreakMode = .byWordWrapping; tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.delegate = context.coordinator; tv.onChange = { text = $0 }
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 84))
        sv.hasVerticalScroller = false; sv.hasHorizontalScroller = false; sv.drawsBackground = false
        sv.backgroundColor = .clear; sv.borderType = .noBorder; sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? HighlightTextView else { return }
        let sel = tv.selectedRange()
        let isFirst = tv.window?.firstResponder == tv

        // Compile once per update
        struct Compiled { let regex: NSRegularExpression; let color: NSColor }
        let compiled: [Compiled] = profile.patterns.filter { $0.enabled }.compactMap { row in
            guard let re = try? NSRegularExpression(pattern: row.pattern, options: [.caseInsensitive]) else { return nil }
            return Compiled(regex: re, color: LogColor.nsColor(for: row.ansiCode))
        }

        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: attr.length))

        // Apply highlights
        for c in compiled {
            for m in c.regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                attr.addAttribute(.foregroundColor, value: c.color, range: m.range)
                attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), range: m.range)
            }
        }

        if tv.string != text || !(tv.textStorage?.isEqual(to: attr) ?? false) {
            tv.textStorage?.setAttributedString(attr)
            if sel.location != NSNotFound && sel.location <= attr.length { tv.setSelectedRange(sel) }
            if isFirst { tv.setSelectedRange(sel) }
        }
        tv.onChange = { text = $0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProfileHighlightField
        init(_ p: ProfileHighlightField) { parent = p }
        func textDidChange(_ n: Notification) { guard let tv = n.object as? NSTextView else { return }; parent.text = tv.string }
    }
}
