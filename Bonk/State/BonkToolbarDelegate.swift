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
    static let serverCPU = NSToolbarItem.Identifier("com.bonk.toolbar.serverCPU")
    static let serverMemory = NSToolbarItem.Identifier("com.bonk.toolbar.serverMemory")
    static let serverDisk = NSToolbarItem.Identifier("com.bonk.toolbar.serverDisk")
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

@MainActor
final class BonkToolbarDelegate: NSObject, NSToolbarDelegate {
    private let coordinator: ToolbarCoordinator
    private var broadcastItem: NSToolbarItem?
    /// Keep every controller alive: toolbar customization recreates items, and
    /// AppKit may keep displaying an earlier instance after the panel closes.
    /// Releasing an active controller leaves a dead target and a frozen ring.
    private var ringItemControllers: [ServerResourceRingItemController] = []

    init(coordinator: ToolbarCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Default Items

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.addHost,
         .toggleSidebar,
         .sidebarTrackingSeparator,
         .serverCPU, .serverMemory, .serverDisk,   // 服务器资源：球形百分比
         .space,
         .broadcast, .sftp, .workspaces,    // 常用：广播、SFTP、工作区
         .flexibleSpace,
         .ai, .snippets]
    }

    // MARK: - Allowed Items (all items user can add)

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.addHost, .toggleSidebar,
         .serverCPU, .serverMemory, .serverDisk,
         .broadcast, .sftp, .workspaces,
         .serialPort, .portForward,         // 不常用：保留在自定义中
         .keyGenerator, .sshImport,
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
                label: coordinator.i18n.t(.toggleSidebar),
                icon: "sidebar.left"
            ) { [weak self] in
                NSApp.keyWindow?.contentViewController?.tryToPerform(
                    #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
                )
            }

        case .serverCPU:
            return makeServerRingItem(id: itemIdentifier, kind: .cpu, label: coordinator.i18n.t(.cpu))

        case .serverMemory:
            return makeServerRingItem(id: itemIdentifier, kind: .memory, label: coordinator.i18n.t(.memory))

        case .serverDisk:
            return makeServerRingItem(id: itemIdentifier, kind: .disk, label: coordinator.i18n.t(.disk))

        case .broadcast:
            let item = makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.broadcastPanes),
                icon: "antenna.radiowaves.left.and.right"
            ) { [weak self] in
                self?.coordinator.workspace.toggleBroadcast()
                self?.refreshBroadcastItemState()
            }
            broadcastItem = item
            observeBroadcastState()
            return item

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

    /// Broadcast on/off state is reflected on the toolbar icon (orange when
    /// enabled), matching the previous SwiftUI toolbar behavior.
    private func refreshBroadcastItemState() {
        guard let broadcastItem else { return }
        let enabled = coordinator.workspace.broadcastManager.isEnabled
        let symbol = NSImage(
            systemSymbolName: "antenna.radiowaves.left.and.right",
            accessibilityDescription: coordinator.i18n.t(.broadcastPanes)
        )
        if enabled {
            broadcastItem.image = symbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            )
        } else {
            broadcastItem.image = symbol
        }
        // NSToolbar can cache the rendered item; force a revalidation so the
        // state change is visible immediately.
        broadcastItem.toolbar?.validateVisibleItems()
    }

    /// Keep the icon in sync even if broadcast is toggled outside this item.
    private func observeBroadcastState() {
        withObservationTracking {
            _ = coordinator.workspace.broadcastManager.isEnabled
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                // withObservationTracking fires before the write is visible,
                // so defer the read to the next runloop turn.
                self?.observeBroadcastState()
                Task { @MainActor [weak self] in
                    self?.refreshBroadcastItemState()
                }
            }
        }
    }

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

    private func makeServerRingItem(
        id: NSToolbarItem.Identifier,
        kind: ServerResourceKind,
        label: String
    ) -> NSToolbarItem {
        let controller = ServerResourceRingItemController(
            id: id,
            kind: kind,
            label: label,
            i18n: coordinator.i18n,
            onShowDetails: { [weak self] in
                self?.coordinator.workspace.toggleRightPanel(.serverInfo)
            }
        )
        ringItemControllers.append(controller)
        return controller.item
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
