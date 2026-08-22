//
//  TerminalStateViews.swift
//  Bonk
//
//  Shared views for terminal connection states.
//

import SwiftUI

/// Shared views for terminal connection states (connecting, disconnected, reconnecting).
@MainActor
enum TerminalStateViews {
    /// Connecting state view with animation.
    @ViewBuilder
    static func connectingView(host: String, username: String, port: Int, i18n: I18n) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: AppStyle.fontGiant))
                .foregroundStyle(.blue.opacity(AppStyle.opacitySecondary))
                .symbolEffect(.variableColor.iterative, options: .repeating)
            ProgressView().controlSize(.large)
            VStack(spacing: 6) {
                Text(i18n.tr(.connectingTo, args: host))
                    .font(.headline)
                Text("\(username)@\(host):\(port)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Disconnected state view with optional reconnect button.
    @ViewBuilder
    static func disconnectedView(
        errorMessage: String?,
        i18n: I18n,
        onReconnect: (() -> Void)?
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: AppStyle.fontHuge))
                .foregroundStyle(.red.opacity(AppStyle.opacityPressed))
            Text(i18n.t(.disconnected)).font(.headline)
            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: AppStyle.panelWidthSmall)
            }
            if let onReconnect {
                Button(i18n.t(.reconnect), systemImage: "arrow.clockwise") { onReconnect() }
                    .buttonStyle(.borderedProminent).padding(.top, AppStyle.spacingM)
            }
        }
    }

    /// Reconnecting state view with progress.
    @ViewBuilder
    static func reconnectingView(attempt: Int, max: Int, i18n: I18n) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(i18n.tr(.reconnecting, args: attempt, max))
                .font(.headline).foregroundStyle(.secondary)
        }
    }
}
