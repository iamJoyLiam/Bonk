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
        HStack(spacing: 0) {
            // Tab area
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(sessionManager.tabs) { tab in
                        tabCapsule(tab)
                            .contextMenu { tabContextMenu(tab) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            // Right controls: + and chevron
            HStack(spacing: 2) {
                addButton
                chevronMenu
            }
            .padding(.trailing, 10)
        }
        .frame(height: 38)
        .background {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .bottom) { Divider() }
        }
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
            onSelect: { sessionManager.selectTab(tab.id) },
            onClose: { Task { await sessionManager.closeTab(tab.id) } }
        )
    }

    // MARK: - Capsule Background

    private func capsuleBackground(tab: TerminalTab, isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(capsuleFill(tab: tab, isActive: isActive))
    }

    /// Capsule fill color: respects color label, neutral when none.
    private func capsuleFill(tab: TerminalTab, isActive: Bool) -> Color {
        if let labelColor = tab.resolvedColor {
            return isActive ? labelColor.opacity(0.3) : labelColor.opacity(0.12)
        }
        // No color label: neutral — slightly elevated for active, transparent for inactive
        return isActive ? Color.primary.opacity(0.1) : Color.clear
    }

    // MARK: - Underline Indicator

    private func capsuleUnderline(tab: TerminalTab) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(tab.resolvedColor ?? Color.primary.opacity(0.5))
            .frame(height: 2)
            .padding(.horizontal, 8)
            .offset(y: 1)
    }

    // MARK: - Status Dot Color

    private func statusDotColor(_ state: SSHConnectionState) -> Color {
        switch state {
        case .connected: .yellow
        case .connecting, .reconnecting: .yellow.opacity(0.5)
        case .disconnected: .secondary.opacity(0.4)
        }
    }

    // MARK: - Right Controls

    private var addButton: some View {
        Menu {
            ForEach(allHosts) { host in
                let isOpen = sessionManager.tabs.contains(where: { $0.hostItem.id == host.id })
                Button {
                    if isOpen {
                        if let tab = sessionManager.tabs.first(where: { $0.hostItem.id == host.id }) {
                            sessionManager.selectTab(tab.id)
                        }
                    } else {
                        sessionManager.openTab(for: host)
                    }
                } label: {
                    Label(host.name, systemImage: isOpen ? "checkmark" : "plus")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var chevronMenu: some View {
        Menu {
            ForEach(sessionManager.tabs) { tab in
                Button { sessionManager.selectTab(tab.id) } label: {
                    HStack {
                        Circle()
                            .fill(statusDotColor(tab.session?.connectionState ?? .disconnected))
                            .frame(width: 6, height: 6)
                        Text(tab.title)
                        if sessionManager.activeTabID == tab.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func tabContextMenu(_ tab: TerminalTab) -> some View {
        Button {
            sessionManager.openTab(for: tab.hostItem)
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
                        Circle().fill(label.color).frame(width: 10, height: 10)
                        Text(label.name.capitalized)
                        if tab.colorLabel == label.name { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
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
