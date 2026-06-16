//
//  BonkToolbar.swift
//  Bonk
//
//  Native NSToolbar using pure subitems layout (no custom NSStackView on groups).
//  Each item is built once and cached by identifier — no double instantiation.
//  Compatible with macOS 26 Tahoe's NSToolbarItemGroup contract.
//

#if os(macOS)
    import AppKit
    import SwiftUI

    // MARK: - Toolbar Item Identifiers

    extension NSToolbarItem.Identifier {
        /// Add host — sits right after the sidebar tracking separator.
        static let addHost = NSToolbarItem.Identifier("bonk.addHost")

        /// Visual group: broadcast | serial · port-forward · sessions
        static let connectionGroup = NSToolbarItem.Identifier("bonk.connectionGroup")
        static let broadcast = NSToolbarItem.Identifier("bonk.broadcast")
        static let connectionSeparator = NSToolbarItem.Identifier("bonk.connectionSeparator")
        static let serialPort = NSToolbarItem.Identifier("bonk.serial")
        static let portForward = NSToolbarItem.Identifier("bonk.portForward")
        static let sessions = NSToolbarItem.Identifier("bonk.session")

        static let sftpButton = NSToolbarItem.Identifier("bonk.sftpButton")

        /// Visual group: AI · Snippets
        static let inspectorGroup = NSToolbarItem.Identifier("bonk.inspectorGroup")
        static let ai = NSToolbarItem.Identifier("bonk.ai")
        static let snippets = NSToolbarItem.Identifier("bonk.snippets")
    }

    // MARK: - Bonk Toolbar Delegate

    final class BonkToolbarDelegate: NSObject, NSToolbarDelegate {
        weak var coordinator: BonkToolbarCoordinator?

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            // [侧栏分隔] [+] [连接组] [📁] —弹性空间— [检查组]
            [
                .sidebarTrackingSeparator,
                .addHost,
                .connectionGroup,
                .sftpButton,
                .flexibleSpace,
                .inspectorGroup,
            ]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            coordinator?.makeItem(for: itemIdentifier)
        }
    }

    // MARK: - Bonk Toolbar Coordinator

    final class BonkToolbarCoordinator {
        private let workspace: WorkspaceManager
        private let i18n: I18n
        private let onToggleSFTP: () -> Void
        private let actions: BonkToolbarActions

        init(
            workspace: WorkspaceManager,
            i18n: I18n,
            onToggleSFTP: @escaping () -> Void
        ) {
            self.workspace = workspace
            self.i18n = i18n
            self.onToggleSFTP = onToggleSFTP

            let actions = BonkToolbarActions()
            actions.workspace = workspace
            actions.onToggleSFTP = onToggleSFTP
            self.actions = actions
        }

        func makeItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
            switch identifier {
            case .sidebarTrackingSeparator, .flexibleSpace:
                // System handles these automatically.
                return nil

            case .addHost:
                return makeAddHostButton()

            case .connectionGroup:
                return makeConnectionGroup()

            case .sftpButton:
                return makeSFTPButton()

            case .inspectorGroup:
                return makeInspectorGroup()

            default:
                return nil
            }
        }

        // MARK: - Connection Group  [📶] | [🔌] [🔀] [⏱]

        private func makeConnectionGroup() -> NSToolbarItemGroup {
            let group = NSToolbarItemGroup(itemIdentifier: .connectionGroup)
            group.subitems = [
                makeButton(
                    id: .broadcast,
                    symbol: "antenna.radiowaves.left.and.right",
                    label: i18n.t(.broadcastMode),
                    action: #selector(BonkToolbarActions.toggleBroadcast)
                ),
                makeSeparatorItem(id: .connectionSeparator),
                makeButton(
                    id: .serialPort,
                    symbol: "cable.connector",
                    label: i18n.t(.serialPort),
                    action: #selector(BonkToolbarActions.showSerialPort)
                ),
                makeButton(
                    id: .portForward,
                    symbol: "arrow.triangle.branch",
                    label: i18n.t(.portForwarding),
                    action: #selector(BonkToolbarActions.showPortForwarding)
                ),
                makeButton(
                    id: .sessions,
                    symbol: "clock.arrow.circlepath",
                    label: i18n.t(.sessions),
                    action: #selector(BonkToolbarActions.showSessions)
                ),
            ]
            group.isNavigational = true
            group.label = i18n.t(.connection)
            return group
        }

        // MARK: - Add Host [+]

        private func makeAddHostButton() -> NSToolbarItem {
            makeButton(
                id: .addHost,
                symbol: "plus",
                label: i18n.t(.addHost),
                action: #selector(BonkToolbarActions.showAddHost)
            )
        }

        // MARK: - SFTP Button [📁]

        private func makeSFTPButton() -> NSToolbarItem {
            makeButton(
                id: .sftpButton,
                symbol: "folder.fill",
                label: i18n.t(.sftpBrowser),
                action: #selector(BonkToolbarActions.toggleSFTP)
            )
        }

        // MARK: - Inspector Group [✨] [📝]

        private func makeInspectorGroup() -> NSToolbarItemGroup {
            let group = NSToolbarItemGroup(itemIdentifier: .inspectorGroup)
            group.subitems = [
                makeButton(
                    id: .ai,
                    symbol: "sparkles",
                    label: i18n.t(.aiAssistant),
                    action: #selector(BonkToolbarActions.toggleAI)
                ),
                makeButton(
                    id: .snippets,
                    symbol: "text.badge.plus",
                    label: i18n.t(.snippets),
                    action: #selector(BonkToolbarActions.toggleSnippets)
                ),
            ]
            group.label = i18n.t(.menuView)
            return group
        }

        // MARK: - Builders

        /// Single source of truth for icon buttons: one NSButton instance per item.
        private func makeButton(
            id: NSToolbarItem.Identifier,
            symbol: String,
            label: String,
            action: Selector
        ) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            let button = NSButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                target: actions,
                action: action
            )
            button.bezelStyle = .recessed
            button.setButtonType(.momentaryPushIn)
            button.showsBorderOnlyWhileMouseInside = true
            item.view = button
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            return item
        }

        /// Thin visual divider inside a group. Rendered via its own item view so the
        /// system (not a custom stack) owns the group's layout.
        private func makeSeparatorItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            let pipe = NSTextField(labelWithString: "|")
            pipe.font = .systemFont(ofSize: 11, weight: .thin)
            pipe.textColor = .secondaryLabelColor
            pipe.alphaValue = 0.5
            pipe.alignment = .center
            item.view = pipe
            item.label = ""
            return item
        }
    }

    // MARK: - Toolbar Actions (target for NSButton)

    final class BonkToolbarActions: NSObject, @unchecked Sendable {
        weak var workspace: WorkspaceManager?
        var onToggleSFTP: (() -> Void)?

        @objc func toggleBroadcast() {
            Task { @MainActor in
                workspace?.toggleBroadcast()
            }
        }

        @objc func showSerialPort() {
            Task { @MainActor in
                workspace?.isSerialPortPresented = true
            }
        }

        @objc func showPortForwarding() {
            Task { @MainActor in
                workspace?.isPortForwardingPresented = true
            }
        }

        @objc func showSessions() {
            Task { @MainActor in
                workspace?.isSessionManagerPresented = true
            }
        }

        @objc func showAddHost() {
            // No-op: add-host is now handled by HostListView's SwiftUI .toolbar.
        }

        @objc func toggleSFTP() {
            Task { @MainActor in
                onToggleSFTP?()
            }
        }

        @objc func toggleAI() {
            Task { @MainActor in
                workspace?.toggleRightPanel(.ai)
            }
        }

        @objc func toggleSnippets() {
            Task { @MainActor in
                workspace?.toggleRightPanel(.snippetsHistory)
            }
        }
    }

#endif
