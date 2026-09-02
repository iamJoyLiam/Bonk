//
//  TerminalTabView+TabBar.swift
//  Bonk
//
//  Capsule-style tab bar with dark-mode design.
//

import SwiftUI
import UniformTypeIdentifiers

extension TerminalTabView {
    var tabBar: some View {
        ViewThatFits(in: .horizontal) {
            // Fits: tabs + plus inline — leading, not centered
            HStack(spacing: AppStyle.tabSpacing) {
                ForEach(sessionManager.tabs) { tab in
                    tabCapsule(tab)
                        .matchedGeometryEffect(id: tab.id, in: tabNamespace)
                        .contextMenu { tabContextMenu(tab) }
                }
                plusButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(AppStyle.animationTab, value: sessionManager.tabs.count)
            .animation(AppStyle.animationTab, value: sessionManager.activeTabID)
            .padding(.horizontal, AppStyle.spacingL)
            .padding(.vertical, AppStyle.tabBarHPadding)

            // Overflow: scroll tabs, plus pinned
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppStyle.tabSpacing) {
                        ForEach(sessionManager.tabs) { tab in
                            tabCapsule(tab)
                                .matchedGeometryEffect(id: tab.id, in: tabNamespace)
                                .contextMenu { tabContextMenu(tab) }
                        }
                        if sessionManager.tabs.count > 1 {
                            Color.clear
                                .frame(width: sessionManager.draggingTabID != nil ? AppStyle.spacingL : 0, height: AppStyle.buttonSmall)
                                .contentShape(Rectangle())
                                .dropDestination(for: String.self) { items, _ in
                                    guard let draggedIDString = items.first,
                                          let draggedID = UUID(uuidString: draggedIDString),
                                          let sourceIndex = sessionManager.tabs.firstIndex(where: { $0.id == draggedID })
                                    else { return false }
                                    let targetIndex = sessionManager.tabs.count - 1
                                    if sourceIndex != targetIndex {
                                        let tab = sessionManager.tabs.remove(at: sourceIndex)
                                        sessionManager.tabs.append(tab)
                                    }
                                    return true
                                }
                        }
                    }
                    .animation(AppStyle.animationTab, value: sessionManager.tabs.count)
                    .animation(AppStyle.animationTab, value: sessionManager.activeTabID)
                    .padding(.horizontal, AppStyle.tabBarHPadding)
                    .padding(.vertical, AppStyle.tabBarHPadding)
                }
                Divider().frame(height: AppStyle.buttonSmall).padding(.horizontal, AppStyle.spacingXS)
                plusButton
                    .padding(.trailing, AppStyle.spacingS)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AppStyle.tabBarHeight)
        .background {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .bottom) { Divider() }
        }
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectView(
                sessionManager: sessionManager,
                isPresented: $showQuickConnect,
                defaultPort: 22
            )
            .environment(i18n)
        }
    }

    private var plusButton: some View {
        Button {
            showQuickConnect = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: AppStyle.fontBody, weight: .medium))
                .foregroundStyle(isHoverPlus ? .primary : .secondary)
                .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                .background {
                    if isHoverPlus {
                        Circle().fill(Color.primary.opacity(AppStyle.opacityBackgroundHover))
                    } else {
                        Circle().fill(Color.primary.opacity(AppStyle.opacityBackgroundSubtle))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("New Tab")
        .onHover { isHoverPlus = $0 }
    }

    // MARK: - Tab Capsule

    @ViewBuilder
    private func tabCapsule(_ tab: TerminalTab) -> some View {
        let isActive = sessionManager.activeTabID == tab.id
        let state = tab.session?.connectionState ?? .disconnected

        DraggableTabCapsule(
            tab: tab,
            isActive: isActive,
            state: state,
            sessionManager: sessionManager,
            isDragEnabled: sessionManager.tabs.count > 1,
            onSelect: { sessionManager.selectTab(tab.id) },
            onClose: { Task { await sessionManager.closeTab(tab.id) } }
        )
    }

    // MARK: - Context Menu

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
