import AppKit
import Carbon
import SwiftUI

// MARK: - Per-field auto English (no global TIS pollution)

private enum EnglishInputSource {
    static func englishID() -> String? {
        guard let list = TISCreateInputSourceList(nil, false)?
            .takeRetainedValue() as? [TISInputSource]
        else { return nil }
        // 1. Exact ABC
        for src in list {
            if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                let identifier = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
                if identifier == "com.apple.keylayout.ABC" { return identifier }
            }
        }
        // 2. Any ABC/US
        for src in list {
            if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                let identifier = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
                if identifier.contains("ABC") || identifier.contains("US") { return identifier }
            }
        }
        // 3. First ASCII-capable
        for src in list {
            if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsASCIICapable) {
                let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
                if CFBooleanGetValue(value),
                   let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                    return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                }
            }
        }
        return nil
    }

    @MainActor
    static func select(for view: NSView) {
        guard let identifier = englishID() else { return }
        // Per-view context (not global TISSelectInputSource)
        view.inputContext?.selectedKeyboardInputSource = identifier
        if let window = view.window,
           let editor = window.fieldEditor(false, for: view) as? NSTextView {
            editor.inputContext?.selectedKeyboardInputSource = identifier
        }
    }
}

// MARK: - AppKit fields

final class AutoEnglishSecureTextField: NSSecureTextField {
    @MainActor
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { EnglishInputSource.select(for: self) }
        return ok
    }
}

final class AutoEnglishTextField: NSTextField {
    @MainActor
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
        let field = AutoEnglishSecureTextField(string: text)
        field.placeholderString = placeholder.isEmpty ? nil : placeholder
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        return field
    }

    func updateNSView(_ nsView: AutoEnglishSecureTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        let placeholderString = placeholder.isEmpty ? nil : placeholder
        if nsView.placeholderString != placeholderString {
            nsView.placeholderString = placeholderString
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutoEnglishSecureField
        init(_ parent: AutoEnglishSecureField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }
    }
}

struct AutoEnglishPlainField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> AutoEnglishTextField {
        let field = AutoEnglishTextField(string: text)
        field.placeholderString = placeholder.isEmpty ? nil : placeholder
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        return field
    }

    func updateNSView(_ nsView: AutoEnglishTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        let placeholderString = placeholder.isEmpty ? nil : placeholder
        if nsView.placeholderString != placeholderString {
            nsView.placeholderString = placeholderString
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutoEnglishPlainField
        init(_ parent: AutoEnglishPlainField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }
    }
}
