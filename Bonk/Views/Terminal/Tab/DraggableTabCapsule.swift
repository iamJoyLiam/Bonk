//
//  DraggableTabCapsule.swift
//  Bonk
//
//  One tab inside the editor-style track. The title stays centered because the
//  close button occupies a slot that is reserved even when it is not drawn.
//

import SwiftUI

// MARK: - Draggable Tab Capsule

struct DraggableTabCapsule: View {
    let tab: TerminalTab
    let isActive: Bool
    var usesGlass = false
    let showsLeadingSeparator: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var onHoverChange: (Bool) -> Void = { _ in }

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHoverClose = false
    @State private var isHoverCapsule = false

    var body: some View {
        title
            .background { surface }
            .overlay(alignment: .leading) { leadingSeparator }
            .overlay(alignment: .leading) { closeButton }
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .onHover { hovering in
                isHoverCapsule = hovering
                onHoverChange(hovering)
            }
            .animation(.easeInOut(duration: 0.12), value: isHoverCapsule)
    }

    /// Spacers at both ends keep the title optically centered. The close
    /// button is a sibling overlay, because a button inside this label would
    /// never receive the click.
    private var title: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: AppStyle.tabAccessoryWidth)
            Text(tab.title)
                .font(.system(size: AppStyle.fontSmall))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: AppStyle.tabAccessoryWidth)
        }
        .padding(.horizontal, AppStyle.tabAccessoryInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titleColor: Color {
        let windowIdle = controlActiveState == .inactive
        if windowIdle {
            return Color(nsColor: isActive ? .secondaryLabelColor : .tertiaryLabelColor)
        }
        return Color(nsColor: isActive ? .labelColor : .secondaryLabelColor)
    }

    @ViewBuilder
    private var surface: some View {
        if isActive {
            if usesGlass {
                GlassCardPlate(cornerRadius: AppStyle.tabHeight / 2)
            } else {
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlColor))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: AppStyle.tabHairline)
                    )
            }
        } else if isHoverCapsule, controlActiveState != .inactive {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .tertiarySystemFill))
        }
    }

    @ViewBuilder
    private var leadingSeparator: some View {
        if showsLeadingSeparator {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: AppStyle.tabHairline, height: AppStyle.tabSeparatorHeight)
        }
    }

    /// Shown on the tab in front, and on any tab the pointer is over.
    @ViewBuilder
    private var closeButton: some View {
        if isActive || (isHoverCapsule && controlActiveState != .inactive) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: AppStyle.tabIconClose, weight: .semibold))
                    .foregroundStyle(Color(nsColor: controlActiveState == .inactive ? .tertiaryLabelColor : .secondaryLabelColor))
                    .frame(width: AppStyle.tabAccessoryWidth, height: AppStyle.tabAccessoryWidth)
                    .background {
                        Circle().fill(isHoverClose ? Color(nsColor: .quaternarySystemFill) : .clear)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .padding(.leading, AppStyle.tabAccessoryInset)
            .onHover { isHoverClose = $0 }
        }
    }
}
