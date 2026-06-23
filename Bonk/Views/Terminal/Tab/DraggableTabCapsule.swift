//
//  DraggableTabCapsule.swift
//  Bonk
//
//  Tab capsule with drag source and drop target support.
//  Drop indicator is shown in the terminal area, not on the tab.
//

import SwiftUI
import UniformTypeIdentifiers

struct DraggableTabCapsule: View {
    let tab: TerminalTab
    let isActive: Bool
    let state: SSHConnectionState
    let sessionManager: SessionManager
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isDragOver = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6, height: 6)

                Text(tab.title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(minWidth: 80, maxWidth: 160)
            .background { capsuleBackground }
            .overlay(alignment: .bottom) {
                if isActive {
                    capsuleUnderline
                }
            }
        }
        .buttonStyle(.plain)
        // Drag source
        .draggable(tab.id.uuidString) {
            Text(tab.title)
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 16).fill(.bar))
        }
    }

    // MARK: - Subviews

    private var capsuleBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(capsuleFill)
    }

    private var capsuleFill: Color {
        if let labelColor = tab.resolvedColor {
            return isActive ? labelColor.opacity(0.3) : labelColor.opacity(0.12)
        }
        return isActive ? Color.primary.opacity(0.1) : Color.clear
    }

    private var capsuleUnderline: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(tab.resolvedColor ?? Color.primary.opacity(0.5))
            .frame(height: 2)
            .padding(.horizontal, 8)
            .offset(y: 1)
    }

    private var statusDotColor: Color {
        switch state {
        case .connected: .green
        case .connecting: .yellow
        case .reconnecting: .orange
        case .disconnected: .red
        }
    }
}
