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
        HStack(spacing: AppStyle.tabSpacing) {
            Circle()
                .fill(statusDotColor)
                .frame(width: AppStyle.statusDotSmall, height: AppStyle.statusDotSmall)

            Text(tab.title)
                .font(.system(size: AppStyle.fontSmall, weight: isActive ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: AppStyle.tabIconClose, weight: .semibold))
                    .foregroundStyle(isHoverClose ? .primary : .secondary)
                    .frame(width: AppStyle.tabCloseSize, height: AppStyle.tabCloseSize)
                    .background {
                        if isHoverClose {
                            Circle().fill(Color.primary.opacity(AppStyle.opacityBackgroundStrong))
                        } else if isActive {
                            Circle().fill(Color.primary.opacity(AppStyle.opacityBackgroundSubtle))
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .onHover { isHoverClose = $0 }
        }
        .padding(.horizontal, AppStyle.tabHPadding)
        .padding(.vertical, AppStyle.tabVPadding)
        .frame(minWidth: AppStyle.tabMinWidth, maxWidth: AppStyle.tabMaxWidth)
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
                    .frame(width: AppStyle.spacingXXS)
                    .padding(.vertical, AppStyle.spacingXS)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: AppStyle.tabCornerRadius, style: .continuous))
        .onTapGesture { onSelect() }
        .onHover { isHoverCapsule = $0 }
        .animation(.easeInOut(duration: 0.12), value: isDragOver)
        .animation(.easeInOut(duration: 0.12), value: isHoverCapsule)
        .draggable(isDragEnabled ? tab.id.uuidString : "") {
            HStack(spacing: AppStyle.tabSpacing) {
                Circle().fill(statusDotColor).frame(width: AppStyle.statusDotSmall, height: AppStyle.statusDotSmall)
                Text(tab.title).font(.system(size: AppStyle.fontSmall, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, AppStyle.spacingL)
            .padding(.vertical, AppStyle.spacingS)
            .background(RoundedRectangle(cornerRadius: AppStyle.tabCornerRadius, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(AppStyle.opacityBackgroundLight), radius: 6, y: 2))
            .contentShape(RoundedRectangle(cornerRadius: AppStyle.tabCornerRadius))
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
        RoundedRectangle(cornerRadius: AppStyle.tabCornerRadius, style: .continuous)
            .fill(capsuleFill)
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: AppStyle.tabCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1)
                }
            }
    }

    private var capsuleFill: Color {
        if let labelColor = tab.resolvedColor {
            return isActive ? labelColor.opacity(AppStyle.opacityTintActive) : labelColor.opacity(AppStyle.opacityTintIdle)
        }
        if isHoverCapsule && !isActive {
            return Color.primary.opacity(AppStyle.opacityBackgroundSubtle)
        }
        return isActive ? Color.primary.opacity(AppStyle.opacityBackgroundHover) : Color.clear
    }

    private var capsuleUnderline: some View {
        RoundedRectangle(cornerRadius: AppStyle.tabCornerRadius, style: .continuous)
            .fill(tab.resolvedColor ?? Color.primary.opacity(AppStyle.opacityDisabled))
            .frame(height: AppStyle.spacingXXS)
            .padding(.horizontal, AppStyle.tabHPadding)
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
