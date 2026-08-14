import AppKit
import SwiftTerm

extension NativeTerminalView {
    // MARK: - Right-Click Paste

    /// NSView-level fallback: catches right-clicks that bypass the event
    /// monitor (e.g. when a hosting view intercepts the event first).
    override func rightMouseDown(with event: NSEvent) {
        if shouldPaste(event: event) { return }
        super.rightMouseDown(with: event)
    }

    /// Right-click pastes the clipboard directly. Right-click with the
    /// configured menu modifier passes through to the context menu.
    func installRightClickPasteMonitor() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            return self.shouldPaste(event: event) ? nil : event
        }
    }

    private func shouldPaste(event: NSEvent) -> Bool {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "right_click_paste_enabled") == nil
            || defaults.bool(forKey: "right_click_paste_enabled")
        guard enabled else { return false }
        let menuModifier = Self.menuModifierFlags()
        guard !event.modifierFlags.contains(menuModifier) else { return false }
        return pasteIfEnabled()
    }

    private static func menuModifierFlags() -> NSEvent.ModifierFlags {
        switch UserDefaults.standard.string(forKey: "right_click_menu_modifier") {
        case "control": .control
        case "option": .option
        case "shift": .shift
        default: .command
        }
    }

    private func pasteIfEnabled() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty
        else { return false }
        MainActor.assumeIsolated {
            terminalDelegate?.send(source: self, data: ArraySlice(text.utf8))
        }
        return true
    }
}
