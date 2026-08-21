//
//  DraggableTabCapsule.swift
//  Bonk
//
//  Tab capsule with drag source and drop target support.
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
    @State private var isHoverClose = false
    @State private var isHoverCapsule = false

    var body: some View {
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
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isHoverClose ? .primary : .secondary)
                    .frame(width: 16, height: 16)
                    .background {
                        if isHoverClose {
                            Circle().fill(Color.primary.opacity(0.12))
                        } else if isActive {
                            Circle().fill(Color.primary.opacity(0.06))
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .onHover { isHoverClose = $0 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 80, maxWidth: 160)
        .background { capsuleBackground }
        .overlay(alignment: .bottom) {
            if isActive {
                capsuleUnderline
            }
        }
        .overlay(alignment: .leading) {
            if isDragOver {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { onSelect() }
        .onHover { isHoverCapsule = $0 }
        .animation(.easeInOut(duration: 0.12), value: isDragOver)
        .animation(.easeInOut(duration: 0.12), value: isHoverCapsule)
        .draggable(isDragEnabled ? tab.id.uuidString : "") {
            HStack(spacing: 6) {
                Circle().fill(statusDotColor).frame(width: 6, height: 6)
                Text(tab.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
            .contentShape(RoundedRectangle(cornerRadius: 16))
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
            isDragOver = isDragEnabled && targeting
        }
    }

    // MARK: - Subviews

    private var capsuleBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(capsuleFill)
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
    }

    private var capsuleFill: Color {
        if let labelColor = tab.resolvedColor {
            return isActive ? labelColor.opacity(0.28) : labelColor.opacity(0.12)
        }
        if isHoverCapsule && !isActive {
            return Color.primary.opacity(0.06)
        }
        return isActive ? Color.primary.opacity(0.10) : Color.clear
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
