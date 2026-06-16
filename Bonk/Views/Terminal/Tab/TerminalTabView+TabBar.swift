//
//  TerminalTabView+TabBar.swift
//  Bonk
//
//  Extracted from TerminalTabView.swift
//

import SwiftUI

extension TerminalTabView {
    var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessionManager.tabs) { tab in
                    tabButton(tab)
                        .contextMenu {
                            Button {
                                // Duplicate: create new connection to same host
                                let host = tab.hostItem
                                sessionManager.openTab(for: host)
                            } label: {
                                Label(i18n.t(.duplicate), systemImage: "plus.square.on.square")
                            }

                            Divider()

                            // Color label submenu
                            Menu {
                                Button {
                                    tab.colorLabel = nil
                                } label: {
                                    Text(i18n.t(.none))
                                }

                                ForEach(TerminalTab.colorLabels, id: \.name) { label in
                                    Button {
                                        tab.colorLabel = label.name
                                    } label: {
                                        HStack {
                                            Circle()
                                                .fill(label.color)
                                                .frame(width: 10, height: 10)
                                            Text(label.name.capitalized)
                                            if tab.colorLabel == label.name {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("Color", systemImage: "paintpalette")
                            }

                            Divider()

                            Button {
                                renamingTab = tab
                            } label: {
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

                // "+" button — click to add host, long-press for menu
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.quaternary.opacity(0.3))
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 40)
        .background {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .bottom) {
                    Divider()
                }
        }
    }

    func tabButton(_ tab: TerminalTab) -> some View {
        let isActive = sessionManager.activeTabID == tab.id
        return Button {
            sessionManager.selectTab(tab.id)
        } label: {
            HStack(spacing: 6) {
                // Connection status indicator
                Circle()
                    .fill(tabColor(tab.connectionState))
                    .frame(width: 5, height: 5)

                Text(tab.title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)

                // Close button - visible on active tab
                if isActive {
                    Button {
                        Task { await sessionManager.closeTab(tab.id) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: 80, maxWidth: 160)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tabAccentColor(tab).opacity(0.15),
                                    tabAccentColor(tab).opacity(0.05),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.clear)
                }
            }
            .overlay(alignment: .bottom) {
                if isActive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tabAccentColor(tab))
                        .frame(height: 2)
                        .offset(y: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Determine tab background color based on color label and active state.
    func tabBackgroundColor(_ tab: TerminalTab, isActive: Bool) -> Color {
        if let color = tab.resolvedColor {
            // Use color label as background with appropriate opacity
            return isActive ? color.opacity(0.25) : color.opacity(0.15)
        }
        // Default: subtle gradient for active, clear for inactive
        return isActive ? Color.accentColor.opacity(0.08) : Color.clear
    }

    /// Determine tab accent color (bottom border) based on color label.
    func tabAccentColor(_ tab: TerminalTab) -> Color {
        if let color = tab.resolvedColor {
            return color.opacity(0.7)
        }
        return Color.accentColor.opacity(0.5)
    }
}
