//
//  TerminalView.swift
//  Bonk
//
//  Created by Joy Liam on 2026/5/25.
//

import SwiftUI

/// Wraps TerminalContainerView with real SSH connection lifecycle.
struct TerminalTabContentView: View {
    @Environment(I18n.self) var i18n
    let tab: TerminalTab
    let colorScheme: TerminalColorScheme
    let fontSize: Double
    let fontFamily: String
    let lineHeight: Double
    let scrollbackLines: Int
    let cursorStyle: String
    let cursorBlink: Bool
    let copyOnSelect: Bool
    let scrollSensitivity: Double
    let onSend: @Sendable (ArraySlice<UInt8>) -> Void
    let onResize: (@Sendable (Int, Int) -> Void)?
    let onTitleChange: (@Sendable (String) -> Void)?
    let onReconnect: (() -> Void)?

    var body: some View {
        ZStack {
            let phase = tab.session?.phase ?? .idle
            switch phase {
            case .idle, .failed:
                disconnectedView
            case .resolving, .connectingTransport, .negotiatingSSH, .authenticating, .fallbacking, .openingChannel, .openingPTY:
                TerminalStateViews.fallbackingView(for: phase, host: tab.hostItem.host, username: tab.hostItem.username, port: tab.hostItem.port, i18n: i18n)
            case .ready:
                if tab.session?.terminalState == .ready {
                    terminalView
                } else {
                    connectingView
                }
            case .reconnecting(let attempt, let max):
                reconnectingView(attempt: attempt, max: max)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground)
    }

    // MARK: - Terminal

    private var terminalView: some View {
        TerminalContainerView(
            activeTab: tab,
            colorScheme: colorScheme,
            fontSize: fontSize,
            fontFamily: fontFamily,
            lineHeight: lineHeight,
            scrollbackLines: scrollbackLines,
            cursorStyle: cursorStyle,
            cursorBlink: cursorBlink,
            copyOnSelect: copyOnSelect,
            scrollSensitivity: scrollSensitivity,
            onSend: onSend,
            onResize: onResize,
            onTitleChange: onTitleChange,
            onReconnect: onReconnect
        )
    }

    // MARK: - States

    private var connectingView: some View {
        TerminalStateViews.connectingView(
            host: tab.hostItem.host,
            username: tab.hostItem.username,
            port: tab.hostItem.port,
            i18n: i18n
        )
    }

    private var disconnectedView: some View {
        TerminalStateViews.disconnectedView(
            errorMessage: tab.session?.errorMessage,
            i18n: i18n,
            onReconnect: onReconnect
        )
    }

    private func reconnectingView(attempt: Int, max: Int) -> some View {
        TerminalStateViews.reconnectingView(attempt: attempt, max: max, i18n: i18n)
    }

    private var terminalBackground: SwiftUI.Color {
        SwiftUI.Color(nsColor: colorScheme.background.nsColor)
    }
}
