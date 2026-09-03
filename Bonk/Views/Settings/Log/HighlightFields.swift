import SwiftUI
import AppKit

// MARK: - HighlightTextView

final class HighlightTextView: NSTextView {
    var onChange: ((String) -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }
    override func becomeFirstResponder() -> Bool { let becomeResult = super.becomeFirstResponder(); needsDisplay = true; return becomeResult }
    override func resignFirstResponder() -> Bool { let resignResult = super.resignFirstResponder(); needsDisplay = true; return resignResult }
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
        let textView = HighlightTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 22))
        textView.isEditable = true; textView.isSelectable = true; textView.drawsBackground = false
        textView.backgroundColor = .clear; textView.focusRingType = .none
        textView.isRichText = true; textView.allowsUndo = true; textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainer?.lineFragmentPadding = 2; textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = true; textView.textContainer?.lineBreakMode = .byTruncatingTail
        textView.delegate = context.coordinator; textView.onChange = { text = $0 }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 22))
        scrollView.hasVerticalScroller = false; scrollView.hasHorizontalScroller = false; scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear; scrollView.borderType = .noBorder; scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HighlightTextView else { return }
        let sel = textView.selectedRange()
        let isFirst = textView.window?.firstResponder == textView
        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: attr.length))
        if let regex = compiled {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                attr.addAttribute(.foregroundColor, value: NSColor(color), range: match.range)
                attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), range: match.range)
            }
        }
        if textView.string != text || !(textView.textStorage?.isEqual(to: attr) ?? false) {
            textView.textStorage?.setAttributedString(attr)
            if sel.location != NSNotFound && sel.location <= attr.length { textView.setSelectedRange(sel) }
            if isFirst { textView.setSelectedRange(sel) }
        }
        textView.onChange = { text = $0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SingleLineHighlightField
        init(_ parentField: SingleLineHighlightField) { parent = parentField }
        func textDidChange(_ notification: Notification) { guard let textView = notification.object as? NSTextView else { return }; parent.text = textView.string }
    }
}

// MARK: - ProfileHighlightField

struct ProfileHighlightField: NSViewRepresentable {
    @Binding var text: String
    var profile: LogProfile

    func makeNSView(context: Context) -> NSScrollView {
        let textView = HighlightTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 84))
        textView.isEditable = true; textView.isSelectable = true; textView.drawsBackground = false
        textView.backgroundColor = .clear; textView.isRichText = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainer?.lineFragmentPadding = 2; textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true; textView.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineBreakMode = .byWordWrapping; textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.delegate = context.coordinator; textView.onChange = { text = $0 }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 84))
        scrollView.hasVerticalScroller = false; scrollView.hasHorizontalScroller = false; scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear; scrollView.borderType = .noBorder; scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HighlightTextView else { return }
        let sel = textView.selectedRange()
        let isFirst = textView.window?.firstResponder == textView

        // Compile once per update
        struct Compiled { let regex: NSRegularExpression; let color: NSColor }
        let compiled: [Compiled] = profile.patterns.filter { $0.enabled }.compactMap { row in
            guard let regex = try? NSRegularExpression(pattern: row.pattern, options: [.caseInsensitive]) else { return nil }
            return Compiled(regex: regex, color: LogColor.nsColor(for: row.ansiCode))
        }

        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: attr.length))

        // Apply highlights
        for compiledItem in compiled {
            for match in compiledItem.regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                attr.addAttribute(.foregroundColor, value: compiledItem.color, range: match.range)
                attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), range: match.range)
            }
        }

        if textView.string != text || !(textView.textStorage?.isEqual(to: attr) ?? false) {
            textView.textStorage?.setAttributedString(attr)
            if sel.location != NSNotFound && sel.location <= attr.length { textView.setSelectedRange(sel) }
            if isFirst { textView.setSelectedRange(sel) }
        }
        textView.onChange = { text = $0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProfileHighlightField
        init(_ parentField: ProfileHighlightField) { parent = parentField }
        func textDidChange(_ notification: Notification) { guard let textView = notification.object as? NSTextView else { return }; parent.text = textView.string }
    }
}
