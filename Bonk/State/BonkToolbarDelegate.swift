//
//  BonkToolbarDelegate.swift
//  Bonk
//
//  NSToolbarDelegate for main window - pure AppKit approach like MarkEdit.
//

import AppKit
import SwiftUI

// MARK: - Toolbar Item Identifiers

extension NSToolbarItem.Identifier {
    // Fixed buttons (immovable)
    static let addHost = NSToolbarItem.Identifier("com.bonk.toolbar.addHost")
    static let toggleSidebar = NSToolbarItem.Identifier("com.bonk.toolbar.toggleSidebar")
    static let ai = NSToolbarItem.Identifier("com.bonk.toolbar.ai")
    static let snippets = NSToolbarItem.Identifier("com.bonk.toolbar.snippets")

    // Movable buttons
    static let broadcast = NSToolbarItem.Identifier("com.bonk.toolbar.broadcast")
    static let serialPort = NSToolbarItem.Identifier("com.bonk.toolbar.serialPort")
    static let portForward = NSToolbarItem.Identifier("com.bonk.toolbar.portForward")
    static let keyGenerator = NSToolbarItem.Identifier("com.bonk.toolbar.keyGenerator")
    static let workspaces = NSToolbarItem.Identifier("com.bonk.toolbar.workspaces")
    static let sshImport = NSToolbarItem.Identifier("com.bonk.toolbar.sshImport")
    static let sftp = NSToolbarItem.Identifier("com.bonk.toolbar.sftp")
}

// MARK: - BonkToolbarDelegate

final class BonkToolbarDelegate: NSObject, NSToolbarDelegate {
    private let coordinator: ToolbarCoordinator

    init(coordinator: ToolbarCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Default Items

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.addHost, .toggleSidebar, .flexibleSpace,
         .broadcast, .serialPort, .portForward,
         .flexibleSpace,
         .keyGenerator, .workspaces,
         .flexibleSpace,
         .sshImport, .sftp,
         .flexibleSpace,
         .ai, .snippets]
    }

    // MARK: - Allowed Items (all items user can add)

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.addHost, .toggleSidebar,
         .broadcast, .serialPort, .portForward,
         .keyGenerator, .workspaces,
         .sshImport, .sftp,
         .ai, .snippets,
         .space, .flexibleSpace]
    }

    // MARK: - Immobile Items (fixed position, cannot be moved)

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.addHost, .toggleSidebar, .ai, .snippets]
    }

    // MARK: - Create Items

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .addHost:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.addHost),
                icon: "plus"
            ) { [weak self] in
                self?.coordinator.showAddHostSheet = true
            }

        case .toggleSidebar:
            return makeItem(
                id: itemIdentifier,
                label: "Toggle Sidebar",
                icon: "sidebar.left"
            ) { [weak self] in
                NSApp.keyWindow?.contentViewController?.tryToPerform(
                    #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
                )
            }

        case .broadcast:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.broadcastPanes),
                icon: "antenna.radiowaves.left.and.right"
            ) { [weak self] in
                self?.coordinator.workspace.toggleBroadcast()
            }

        case .serialPort:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.serialPort),
                icon: "cable.connector"
            ) { [weak self] in
                self?.coordinator.workspace.isSerialPortPresented = true
            }

        case .portForward:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.portForwarding),
                icon: "arrow.triangle.branch"
            ) { [weak self] in
                self?.coordinator.workspace.isPortForwardingPresented = true
            }

        case .keyGenerator:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.generateSSHKey),
                icon: "key.fill"
            ) { [weak self] in
                self?.coordinator.showKeyGenerator = true
            }

        case .workspaces:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.workspaces),
                icon: "square.stack.3d.up"
            ) { [weak self] in
                self?.coordinator.showWorkspaces = true
            }

        case .sshImport:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.importSSHConfig),
                icon: "square.and.arrow.down"
            ) { [weak self] in
                self?.coordinator.showSSHConfigImport = true
            }

        case .sftp:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.sftpBrowser),
                icon: "folder.fill"
            ) { [weak self] in
                self?.coordinator.workspace.toggleSFTPWindow()
            }

        case .ai:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.aiAssistant),
                icon: "sparkles"
            ) { [weak self] in
                self?.coordinator.workspace.toggleRightPanel(.ai)
            }

        case .snippets:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.snippets),
                icon: "text.badge.plus"
            ) { [weak self] in
                self?.coordinator.showSnippets()
            }

        default:
            return nil
        }
    }

    // MARK: - Helper

    private func makeItem(
        id: NSToolbarItem.Identifier,
        label: String,
        icon: String,
        action: @escaping @MainActor () -> Void
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)

        // Use target-action pattern
        let target = ToolbarItemTarget(action: { @MainActor in action() })
        objc_setAssociatedObject(item, "target", target, .OBJC_ASSOCIATION_RETAIN)
        item.target = target
        item.action = #selector(ToolbarItemTarget.invokeAction)

        return item
    }
}

// MARK: - Target for toolbar items

private final class ToolbarItemTarget: NSObject {
    let action: @MainActor () -> Void
    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init()
    }
    @objc @MainActor func invokeAction() {
        action()
    }
}
