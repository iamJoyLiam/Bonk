//
//  CommandRegistry.swift
//  Bonk
//

import SwiftUI

/// Builds the list of available commands for the command palette.
enum CommandRegistry {
    @MainActor
    static func buildCommands(
        sessionManager: SessionManager,
        i18n: I18n,
        onToggleAI: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        onChangeTheme: @escaping (String) -> Void
    ) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []

        // MARK: - Connection Commands

        commands.append(PaletteCommand(
            name: i18n.t(.addHost),
            category: i18n.t(.categoryConnection),
            icon: "plus.circle",
            shortcut: nil,
            action: {}
        ))

        if let activeTab = sessionManager.activeTab {
            if activeTab.connectionState.isConnected {
                commands.append(PaletteCommand(
                    name: i18n.t(.disconnect),
                    category: i18n.t(.categoryConnection),
                    icon: "bolt.slash",
                    shortcut: nil,
                    action: {
                        Task { await sessionManager.disconnectTab(activeTab.id) }
                    }
                ))
                commands.append(PaletteCommand(
                    name: i18n.t(.reconnect),
                    category: i18n.t(.categoryConnection),
                    icon: "arrow.clockwise",
                    shortcut: nil,
                    action: {
                        Task { await sessionManager.reconnectTab(activeTab.id) }
                    }
                ))
            } else {
                commands.append(PaletteCommand(
                    name: i18n.t(.connect),
                    category: i18n.t(.categoryConnection),
                    icon: "bolt",
                    shortcut: nil,
                    action: {
                        Task { await sessionManager.reconnectTab(activeTab.id) }
                    }
                ))
            }
        }

        // MARK: - Tab Commands

        commands.append(PaletteCommand(
            name: i18n.t(.newTerminal),
            category: i18n.t(.categoryTabs),
            icon: "plus.square",
            shortcut: "⌘T",
            action: {
                NotificationCenter.default.post(name: .newTerminal, object: nil)
            }
        ))

        if sessionManager.activeTab != nil {
            commands.append(PaletteCommand(
                name: i18n.t(.closeTab),
                category: i18n.t(.categoryTabs),
                icon: "xmark.square",
                shortcut: "⌘W",
                action: {
                    if let id = sessionManager.activeTabID {
                        Task { await sessionManager.closeTab(id) }
                    }
                }
            ))
            commands.append(PaletteCommand(
                name: i18n.t(.clearTerminalCmd),
                category: i18n.t(.categoryTerminal),
                icon: "trash",
                shortcut: "⌘K",
                action: {
                    NotificationCenter.default.post(name: .clearTerminal, object: nil)
                }
            ))
        }

        // MARK: - AI Commands

        commands.append(PaletteCommand(
            name: i18n.t(.aiAssistant),
            category: i18n.t(.ai),
            icon: "sparkles",
            shortcut: "⌘⇧A",
            action: onToggleAI
        ))

        // MARK: - Theme Commands

        for theme in ThemeRegistry.primary {
            commands.append(PaletteCommand(
                name: "\(i18n.t(.theme)): \(theme.name)",
                category: i18n.t(.appearance),
                icon: "paintbrush",
                shortcut: nil,
                action: { onChangeTheme(theme.id) }
            ))
        }

        for theme in ThemeRegistry.extra {
            commands.append(PaletteCommand(
                name: "\(i18n.t(.theme)): \(theme.name)",
                category: i18n.t(.appearance),
                icon: "paintbrush",
                shortcut: nil,
                action: { onChangeTheme(theme.id) }
            ))
        }

        // MARK: - Session Commands

        commands.append(PaletteCommand(
            name: i18n.t(.sessions),
            category: i18n.t(.categoryConnection),
            icon: "clock.arrow.circlepath",
            shortcut: nil,
            action: {
                NotificationCenter.default.post(name: .showSessions, object: nil)
            }
        ))

        // MARK: - Serial Port

        commands.append(PaletteCommand(
            name: "Serial Port",
            category: i18n.t(.categoryConnection),
            icon: "cable.connector",
            shortcut: nil,
            action: {
                NotificationCenter.default.post(name: .showSerialPort, object: nil)
            }
        ))

        // MARK: - Jump Host

        commands.append(PaletteCommand(
            name: "Jump Hosts",
            category: i18n.t(.categoryConnection),
            icon: "arrow.triangle.swap",
            shortcut: nil,
            action: {
                NotificationCenter.default.post(name: .showJumpHosts, object: nil)
            }
        ))

        // MARK: - Shell Integration

        commands.append(PaletteCommand(
            name: "Command History",
            category: i18n.t(.categoryTerminal),
            icon: "clock",
            shortcut: nil,
            action: {
                NotificationCenter.default.post(name: .showCommandHistory, object: nil)
            }
        ))

        // MARK: - Port Forwarding

        commands.append(PaletteCommand(
            name: i18n.t(.portForwarding),
            category: i18n.t(.categoryConnection),
            icon: "arrow.triangle.branch",
            shortcut: nil,
            action: {
                NotificationCenter.default.post(name: .showPortForwarding, object: nil)
            }
        ))

        // MARK: - Split Pane Commands

        if let activeTab = sessionManager.activeTab {
            let tabID = activeTab.id
            commands.append(PaletteCommand(
                name: "Split Horizontal",
                category: i18n.t(.categoryTerminal),
                icon: "rectangle.split.2x1",
                shortcut: "⌘D",
                action: {
                    NotificationCenter.default.post(name: .splitHorizontal, object: tabID)
                }
            ))
            commands.append(PaletteCommand(
                name: "Split Vertical",
                category: i18n.t(.categoryTerminal),
                icon: "rectangle.split.1x2",
                shortcut: "⌘⇧D",
                action: {
                    NotificationCenter.default.post(name: .splitVertical, object: tabID)
                }
            ))
            if activeTab.splitPane.paneCount > 1 {
                commands.append(PaletteCommand(
                    name: "Close Pane",
                    category: i18n.t(.categoryTerminal),
                    icon: "xmark.rectangle",
                    shortcut: "⌘⇧W",
                    action: {
                        NotificationCenter.default.post(name: .closePane, object: tabID)
                    }
                ))
            }
        }

        // MARK: - Snippets

        commands.append(PaletteCommand(
            name: i18n.t(.snippets),
            category: i18n.t(.categoryTerminal),
            icon: "text.badge.plus",
            shortcut: nil,
            action: {
                NotificationCenter.default.post(name: .showSnippets, object: nil)
            }
        ))

        // MARK: - Settings

        commands.append(PaletteCommand(
            name: i18n.t(.settings),
            category: i18n.t(.general),
            icon: "gear",
            shortcut: "⌘,",
            action: onShowSettings
        ))

        return commands
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newTerminal = Notification.Name("bonk.newTerminal")
    static let clearTerminal = Notification.Name("bonk.clearTerminal")
    static let showSnippets = Notification.Name("bonk.showSnippets")
    static let splitHorizontal = Notification.Name("bonk.splitHorizontal")
    static let splitVertical = Notification.Name("bonk.splitVertical")
    static let closePane = Notification.Name("bonk.closePane")
    static let showSessions = Notification.Name("bonk.showSessions")
    static let showPortForwarding = Notification.Name("bonk.showPortForwarding")
    static let showCommandHistory = Notification.Name("bonk.showCommandHistory")
    static let showJumpHosts = Notification.Name("bonk.showJumpHosts")
    static let showSerialPort = Notification.Name("bonk.showSerialPort")
}
