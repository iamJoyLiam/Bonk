//
//  FocusedValues.swift
//  Bonk
//
//  FocusedSceneValue keys for menu bar state distribution.
//

import SwiftUI

/// Active terminal session state for menu bar commands.
struct ActiveTerminalState {
    let tabID: UUID
    let isConnected: Bool
    let sendInput: @MainActor (ArraySlice<UInt8>) -> Void
    let reconnect: @MainActor () -> Void
    let disconnect: @MainActor () -> Void
}

/// FocusedValueKey for the active terminal session.
struct ActiveTerminalKey: FocusedValueKey {
    typealias Value = ActiveTerminalState
}

// MARK: - Menu Action Keys

struct MenuCloseTabKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuNewTerminalKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuConnectKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuDisconnectKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuReconnectKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuToggleSFTPKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuToggleAIKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuShowSerialPortKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuShowSnippetsKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuShowPortForwardingKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuShowCommandHistoryKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuChangeThemeKey: FocusedValueKey { typealias Value = @MainActor (String) -> Void }
struct MenuSplitHorizontalKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuSplitVerticalKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuClosePaneKey: FocusedValueKey { typealias Value = @MainActor () -> Void }
struct MenuFindKey: FocusedValueKey { typealias Value = @MainActor () -> Void }

// MARK: - FocusedValues Extension

extension FocusedValues {
    var activeTerminal: ActiveTerminalKey.Value? {
        get { self[ActiveTerminalKey.self] }
        set { self[ActiveTerminalKey.self] = newValue }
    }

    var menuCloseTab: MenuCloseTabKey.Value? {
        get { self[MenuCloseTabKey.self] }
        set { self[MenuCloseTabKey.self] = newValue }
    }

    var menuNewTerminal: MenuNewTerminalKey.Value? {
        get { self[MenuNewTerminalKey.self] }
        set { self[MenuNewTerminalKey.self] = newValue }
    }

    var menuConnect: MenuConnectKey.Value? {
        get { self[MenuConnectKey.self] }
        set { self[MenuConnectKey.self] = newValue }
    }

    var menuDisconnect: MenuDisconnectKey.Value? {
        get { self[MenuDisconnectKey.self] }
        set { self[MenuDisconnectKey.self] = newValue }
    }

    var menuReconnect: MenuReconnectKey.Value? {
        get { self[MenuReconnectKey.self] }
        set { self[MenuReconnectKey.self] = newValue }
    }

    var menuToggleSFTP: MenuToggleSFTPKey.Value? {
        get { self[MenuToggleSFTPKey.self] }
        set { self[MenuToggleSFTPKey.self] = newValue }
    }

    var menuToggleAI: MenuToggleAIKey.Value? {
        get { self[MenuToggleAIKey.self] }
        set { self[MenuToggleAIKey.self] = newValue }
    }

    var menuShowSerialPort: MenuShowSerialPortKey.Value? {
        get { self[MenuShowSerialPortKey.self] }
        set { self[MenuShowSerialPortKey.self] = newValue }
    }

    var menuShowSnippets: MenuShowSnippetsKey.Value? {
        get { self[MenuShowSnippetsKey.self] }
        set { self[MenuShowSnippetsKey.self] = newValue }
    }

    var menuShowPortForwarding: MenuShowPortForwardingKey.Value? {
        get { self[MenuShowPortForwardingKey.self] }
        set { self[MenuShowPortForwardingKey.self] = newValue }
    }

    var menuShowCommandHistory: MenuShowCommandHistoryKey.Value? {
        get { self[MenuShowCommandHistoryKey.self] }
        set { self[MenuShowCommandHistoryKey.self] = newValue }
    }

    var menuChangeTheme: MenuChangeThemeKey.Value? {
        get { self[MenuChangeThemeKey.self] }
        set { self[MenuChangeThemeKey.self] = newValue }
    }

    var menuSplitHorizontal: MenuSplitHorizontalKey.Value? {
        get { self[MenuSplitHorizontalKey.self] }
        set { self[MenuSplitHorizontalKey.self] = newValue }
    }

    var menuSplitVertical: MenuSplitVerticalKey.Value? {
        get { self[MenuSplitVerticalKey.self] }
        set { self[MenuSplitVerticalKey.self] = newValue }
    }

    var menuClosePane: MenuClosePaneKey.Value? {
        get { self[MenuClosePaneKey.self] }
        set { self[MenuClosePaneKey.self] = newValue }
    }

    var menuFind: MenuFindKey.Value? {
        get { self[MenuFindKey.self] }
        set { self[MenuFindKey.self] = newValue }
    }
}
