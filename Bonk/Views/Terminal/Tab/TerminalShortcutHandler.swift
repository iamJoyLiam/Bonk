import SwiftUI

/// Applies direct terminal shortcut notifications to SessionManager actions.
/// Kept as its own modifier so TerminalTabView's body stays type-checkable.
struct TerminalShortcutHandler: ViewModifier {
    let sessionManager: SessionManager
    @State private var lastHandledAt: [Notification.Name: Date] = [:]

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .terminalCloseTab)) { _ in
                handle(.terminalCloseTab) {
                    if let tabID = sessionManager.activeTabID {
                        Task { await sessionManager.closeTab(tabID) }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalClosePane)) { _ in
                handle(.terminalClosePane) { sessionManager.closePane() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalSplitHorizontal)) { _ in
                handle(.terminalSplitHorizontal) { sessionManager.splitHorizontal() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalSplitVertical)) { _ in
                handle(.terminalSplitVertical) { sessionManager.splitVertical() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalReconnect)) { _ in
                handle(.terminalReconnect) {
                    if let tabID = sessionManager.activeTabID {
                        Task { await sessionManager.reconnectTab(tabID) }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalClear)) { _ in
                handle(.terminalClear) { clearActiveTerminal() }
            }
    }

    /// Multiple terminal views can share a window; each may post the same
    /// shortcut notification. Ignore repeats within 200ms.
    private func handle(_ name: Notification.Name, _ action: @escaping () -> Void) {
        let now = Date()
        if let last = lastHandledAt[name], now.timeIntervalSince(last) < 0.2 { return }
        lastHandledAt[name] = now
        action()
    }

    private func clearActiveTerminal() {
        let clearBytes: [UInt8] = [12]
        if let tabID = sessionManager.activeTabID {
            Task {
                try? await sessionManager.sendInput(clearBytes[...], to: tabID)
            }
        }
    }
}

extension View {
    func terminalShortcuts(_ sessionManager: SessionManager) -> some View {
        modifier(TerminalShortcutHandler(sessionManager: sessionManager))
    }
}
