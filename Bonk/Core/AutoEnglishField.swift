import AppKit
import Carbon
import SwiftUI

// MARK: - Per-field auto English (no global TIS pollution)

private enum EnglishInputSource {
    static func englishID() -> String? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        // 1. Exact ABC
        for src in list {
            if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
                if id == "com.apple.keylayout.ABC" { return id }
            }
        }
        // 2. Any ABC/US
        for src in list {
            if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
                if id.contains("ABC") || id.contains("US") { return id }
            }
        }
        // 3. First ASCII-capable
        for src in list {
            if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsASCIICapable) {
                let v = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
                if CFBooleanGetValue(v),
                   let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                    return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                }
            }
        }
        return nil
    }

    static func select(for view: NSView) {
        guard let id = englishID() else { return }
        // Per-view context (not global TISSelectInputSource)
        view.inputContext?.selectedKeyboardInputSource = id
        if let win = view.window, let editor = win.fieldEditor(false, for: view) as? NSTextView {
            editor.inputContext?.selectedKeyboardInputSource = id
        }
    }
}

// MARK: - AppKit fields

final class AutoEnglishSecureTextField: NSSecureTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { EnglishInputSource.select(for: self) }
        return ok
    }
}

final class AutoEnglishTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { EnglishInputSource.select(for: self) }
        return ok
    }
}

// MARK: - SwiftUI wrappers (Form style, no visible bezel)

struct AutoEnglishSecureField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> AutoEnglishSecureTextField {
        let f = AutoEnglishSecureTextField(string: text)
        f.placeholderString = placeholder.isEmpty ? nil : placeholder
        f.delegate = context.coordinator
        f.isBezeled = false
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.alignment = .right
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.lineBreakMode = .byClipping
        return f
    }

    func updateNSView(_ nsView: AutoEnglishSecureTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        let ph = placeholder.isEmpty ? nil : placeholder
        if nsView.placeholderString != ph { nsView.placeholderString = ph }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutoEnglishSecureField
        init(_ parent: AutoEnglishSecureField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            if parent.text != f.stringValue { parent.text = f.stringValue }
        }
    }
}

struct AutoEnglishPlainField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> AutoEnglishTextField {
        let f = AutoEnglishTextField(string: text)
        f.placeholderString = placeholder.isEmpty ? nil : placeholder
        f.delegate = context.coordinator
        f.isBezeled = false
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.alignment = .right
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.lineBreakMode = .byClipping
        return f
    }

    func updateNSView(_ nsView: AutoEnglishTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        let ph = placeholder.isEmpty ? nil : placeholder
        if nsView.placeholderString != ph { nsView.placeholderString = ph }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutoEnglishPlainField
        init(_ parent: AutoEnglishPlainField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            if parent.text != f.stringValue { parent.text = f.stringValue }
        }
    }
}
