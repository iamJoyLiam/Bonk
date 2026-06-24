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
                HStack(spacing: 6) {
                    ForEach(sessionManager.tabs) { tab in
                        tabCapsule(tab)
                            .contextMenu { tabContextMenu(tab) }
                    }

                    // + button at the end of tabs
                    Button {
                        showQuickConnect = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(height: 44)
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

    // MARK: - Context Menu

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
