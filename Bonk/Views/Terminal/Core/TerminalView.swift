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
    let onSend: @Sendable (ArraySlice<UInt8>) -> Void
    let onResize: (@Sendable (Int, Int) -> Void)?
    let onTitleChange: (@Sendable (String) -> Void)?
    let onReconnect: (() -> Void)?

    var body: some View {
        ZStack {
            switch tab.session?.connectionState ?? .disconnected {
            case .disconnected:
                disconnectedView
            case .connecting:
                connectingView
            case .connected:
                terminalView
            case let .reconnecting(attempt, max):
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
            onSend: onSend,
            onResize: onResize,
            onTitleChange: onTitleChange,
            onReconnect: onReconnect
        )
    }

    // MARK: - States

    private var connectingView: some View {
        VStack(spacing: 20) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.blue.opacity(0.7))
                .symbolEffect(.variableColor.iterative, options: .repeating)

            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text(i18n.tr(.connectingTo, args: tab.hostItem.host))
                    .font(.headline)

                Text("\(tab.hostItem.username)@\(tab.hostItem.host):\(tab.hostItem.port)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red.opacity(0.6))

            Text(i18n.t(.disconnected))
                .font(.headline)

            if let error = tab.session?.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if let onReconnect {
                Button(i18n.t(.reconnect), systemImage: "arrow.clockwise") {
                    onReconnect()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
    }

    private func reconnectingView(attempt: Int, max: Int) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text(i18n.tr(.reconnecting, args: attempt, max))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var terminalBackground: SwiftUI.Color {
        if colorScheme.id == "transparent" { return .clear }
        return SwiftUI.Color(nsColor: .controlBackgroundColor)
    }
}
