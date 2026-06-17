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

extension FocusedValues {
    var activeTerminal: ActiveTerminalKey.Value? {
        get { self[ActiveTerminalKey.self] }
        set { self[ActiveTerminalKey.self] = newValue }
    }
}
