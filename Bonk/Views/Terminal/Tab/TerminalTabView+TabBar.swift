//
//  TerminalTabView+TabBar.swift
//  Bonk
//
//  Editor-style tab strip: a filled track, the selected tab raised inside it,
//  and the new-tab button outside the track.
//

import SwiftUI
import UniformTypeIdentifiers

extension TerminalTabView {
    var tabBar: some View {
        HStack(alignment: .top, spacing: AppStyle.tabTrackSpacing) {
            tabTrack
            plusButton
                .frame(width: AppStyle.tabNewButtonSize, height: AppStyle.tabTrackHeight)
        }
        .padding(.horizontal, AppStyle.tabStripInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AppStyle.tabTrackHeight)
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectView(
                sessionManager: sessionManager,
                isPresented: $showQuickConnect,
                defaultPort: 22
            )
            .environment(i18n)
        }
    }

    /// Tabs share the track. They stop shrinking at a width that still fits a
    /// name, and the rest scrolls instead of collapsing into slivers.
    private var tabTrack: some View {
        GeometryReader { proxy in
            let tabs = sessionManager.tabs
            let usable = max(proxy.size.width - AppStyle.tabTrackPadding * 2, 0)
            let tabWidth = AppStyle.tabWidth(forTrack: usable, count: tabs.count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        tabCapsule(tab, showsLeadingSeparator: showsSeparator(before: index, in: tabs))
                            .matchedGeometryEffect(id: tab.id, in: tabNamespace)
                            .contextMenu { tabContextMenu(tab) }
                            .frame(width: tabWidth, height: AppStyle.tabHeight)
                    }
                }
                .padding(AppStyle.tabTrackPadding)
            }
            .contentMargins(0, for: .scrollContent)
            .frame(width: proxy.size.width, height: AppStyle.tabTrackHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppStyle.tabTrackHeight)
        .background {
            if glassTabs {
                GlassCardPlate(cornerRadius: AppStyle.tabTrackHeight / 2)
            } else {
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color(nsColor: .quinaryLabel), lineWidth: AppStyle.tabHairline)
                    )
            }
        }
        .clipShape(Capsule(style: .continuous))
        .animation(AppStyle.animationTab, value: sessionManager.tabs.count)
        .animation(AppStyle.animationTab, value: sessionManager.activeTabID)
    }

    /// A hairline sits between two plain tabs. One against the raised capsule
    /// reads as a seam in it, so a selected tab suppresses both of its edges.
    private func showsSeparator(before index: Int, in tabs: [TerminalTab]) -> Bool {
        guard index > 0, tabs.indices.contains(index) else { return false }
        let leading = tabs[index - 1].id
        let trailing = tabs[index].id
        let selected = sessionManager.activeTabID
        guard leading != selected, trailing != selected else { return false }
        return leading != hoveredTabID && trailing != hoveredTabID
    }

    private var plusButton: some View {
        EditorNewTabButton(isHovering: isHoverPlus, usesGlass: glassTabs) {
            showQuickConnect = true
        }
        .onHover { isHoverPlus = $0 }
    }

    /// Same switch as the terminal cards. Older systems have no button glass.
    private var glassTabs: Bool {
        PaneChrome.glassCardEnabled(
            preference: preferences.terminalGlassCard,
            systemSupportsGlass: PaneChrome.systemSupportsGlassCards
        )
    }

    @ViewBuilder
    private func tabCapsule(_ tab: TerminalTab, showsLeadingSeparator: Bool) -> some View {
        let isActive = sessionManager.activeTabID == tab.id

        DraggableTabCapsule(
            tab: tab,
            isActive: isActive,
            usesGlass: glassTabs,
            showsLeadingSeparator: showsLeadingSeparator,
            sessionManager: sessionManager,
            isDragEnabled: sessionManager.tabs.count > 1,
            onSelect: { sessionManager.selectTab(tab.id) },
            onClose: { Task { await sessionManager.closeTab(tab.id) } },
            onHoverChange: { hovering in
                hoveredTabID = hovering ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
            }
        )
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func tabContextMenu(_ tab: TerminalTab) -> some View {
        Button {
            sessionManager.openHost(tab.hostItem)
        } label: {
            Label(i18n.t(.duplicate), systemImage: "plus.square.on.square")
        }

        Divider()

        Menu {
            Button { tab.colorLabel = nil } label: {
                Text(i18n.t(.none))
            }
            ForEach(TerminalTab.colorLabels, id: \.name) { label in
                Button { tab.colorLabel = label.name } label: {
                    HStack {
                        Circle().fill(label.color).frame(width: AppStyle.iconMedium, height: AppStyle.iconMedium)
                        Text(label.name.capitalized)
                        if tab.colorLabel == label.name { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Label(i18n.t(.color), systemImage: "paintpalette")
        }

        Divider()

        Button { renamingTab = tab } label: {
            Label(i18n.t(.rename), systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            Task { await sessionManager.closeTab(tab.id) }
        } label: {
            Label(i18n.t(.close), systemImage: "xmark")
        }
    }
}

/// Sits outside the track. A light appearance gets the same soft rim the
/// system tab bar uses; in dark the fill alone is the edge.
private struct EditorNewTabButton: View {
    let isHovering: Bool
    var usesGlass = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: AppStyle.fontBody, weight: .medium))
                .foregroundStyle(Color(nsColor: isHovering ? .labelColor : .secondaryLabelColor))
                .frame(width: AppStyle.tabNewButtonSize, height: AppStyle.tabNewButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            if usesGlass {
                GlassCardPlate(cornerRadius: AppStyle.tabNewButtonSize / 2)
            } else {
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .shadow(
                        color: Color(nsColor: .shadowColor).opacity(colorScheme == .light ? AppStyle.opacityBackgroundStrong : 0),
                        radius: colorScheme == .light ? AppStyle.sizeHairline : 0,
                        y: colorScheme == .light ? AppStyle.tabHairline : 0
                    )
            }
        }
        .help("New Tab")
    }
}
