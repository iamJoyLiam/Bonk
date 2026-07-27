//
//  DraggableTabCapsule.swift
//  Bonk
//
//  Tab capsule with drag source and drop target support.
//  Simple and reliable: .draggable() + .dropDestination with smooth animation.
//

import SwiftUI

// MARK: - Draggable Tab Capsule

struct DraggableTabCapsule: View {
    let tab: TerminalTab
    let isActive: Bool
    let state: SSHConnectionState
    let sessionManager: SessionManager
    let isDragEnabled: Bool
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
            .overlay {
                if isDragOver {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .padding(1)
                }
            }
        }
        .buttonStyle(.plain)
        .draggable(isDragEnabled ? tab.id.uuidString : "") {
            Text(tab.title)
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 16).fill(.bar))
        }
        .dropDestination(for: String.self) { items, _ in
            guard isDragEnabled,
                  let draggedIDString = items.first,
                  let draggedID = UUID(uuidString: draggedIDString),
                  draggedID != tab.id
            else {
                return false
            }
            sessionManager.moveTab(draggedID, relativeTo: tab.id)
            return true
        } isTargeted: { targeting in
            withAnimation(.easeInOut(duration: 0.15)) {
                isDragOver = isDragEnabled && targeting
            }
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
