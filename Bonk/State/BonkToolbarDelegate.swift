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
    private var broadcastObserving = false
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
            let label = coordinator.i18n.t(.broadcastPanes)
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: label)

            let target = BroadcastToolbarItemTarget(
                label: label,
                isEnabled: { [weak self] in
                    self?.coordinator.workspace.broadcastManager.isEnabled ?? false
                },
                action: { [weak self, weak item] in
                self?.coordinator.workspace.toggleBroadcast()
                    item?.toolbar?.validateVisibleItems()
                }
            )
            objc_setAssociatedObject(item, "broadcastTarget", target, .OBJC_ASSOCIATION_RETAIN)
            item.target = target
            item.action = #selector(BroadcastToolbarItemTarget.invoke)
            if !broadcastObserving {
                broadcastObserving = true
                observeBroadcastState()
            }
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

    /// Keep the icon in sync even if broadcast is toggled outside this item.
    /// Validation runs on every visible item, so whichever instance AppKit is
    /// displaying updates itself.
    private func observeBroadcastState() {
        withObservationTracking {
            _ = coordinator.workspace.broadcastManager.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                // withObservationTracking fires before the write is visible,
                // so defer the read to the next runloop turn.
                self?.observeBroadcastState()
                NSApp.keyWindow?.toolbar?.validateVisibleItems()
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

/// Broadcast item target: updates its own icon during NSToolbar validation.
@MainActor
private final class BroadcastToolbarItemTarget: NSObject, NSToolbarItemValidation {
    private let label: String
    private let isEnabled: @MainActor () -> Bool
    private let action: @MainActor () -> Void

    init(
        label: String,
        isEnabled: @escaping @MainActor () -> Bool,
        action: @escaping @MainActor () -> Void
    ) {
        self.label = label
        self.isEnabled = isEnabled
        self.action = action
        super.init()
    }

    @objc @MainActor func invoke() {
        action()
    }

    nonisolated func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        MainActor.assumeIsolated {
            let symbol = NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right",
                accessibilityDescription: label
            )
            if isEnabled() {
                item.image = symbol?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
                )
            } else {
                item.image = symbol
            }
        }
        return true
    }
}
