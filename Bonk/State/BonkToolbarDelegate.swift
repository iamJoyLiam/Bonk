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
    static let importSessions = NSToolbarItem.Identifier("com.bonk.toolbar.importSessions")
    static let triggers = NSToolbarItem.Identifier("com.bonk.toolbar.triggers")
    // legacy: kept for toolbar migration, now merged into importSessions
    static let sshImport = NSToolbarItem.Identifier("com.bonk.toolbar.sshImport")
    static let tabbyImport = NSToolbarItem.Identifier("com.bonk.toolbar.tabbyImport")
    static let sftp = NSToolbarItem.Identifier("com.bonk.toolbar.sftp")
    static let recording = NSToolbarItem.Identifier("com.bonk.toolbar.recording")
    static let jumpHosts = NSToolbarItem.Identifier("com.bonk.toolbar.jumpHosts")
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
         .broadcast, .sftp, .workspaces,    // 常用：广播、SFTP、工作区（录制仅自定义）
         .flexibleSpace,
         .ai, .snippets]
    }

    // MARK: - Allowed Items (all items user can add)

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.addHost, .toggleSidebar,
         .serverCPU, .serverMemory, .serverDisk,
         .broadcast, .sftp, .workspaces, .recording, .jumpHosts,
         .serialPort, .portForward,         // 不常用：保留在自定义中
         .keyGenerator, .importSessions, .triggers,
         .ai, .snippets,
         .space, .flexibleSpace]
    }

    // MARK: - Immobile Items (fixed position, cannot be moved)

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
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
            ) {
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

        case .importSessions:
            return makeImportMenuItem(id: itemIdentifier)

        case .triggers:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.triggers),
                icon: "bolt.trianglebadge.exclamationmark"
            ) { [weak self] in
                self?.coordinator.showTriggers = true
            }

        case .sftp:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.sftpBrowser),
                icon: "folder.fill"
            ) { [weak self] in
                self?.coordinator.workspace.toggleSFTPWindow()
            }

        case .recording:
            let label = coordinator.i18n.t(.recording)
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = label; item.paletteLabel = label; item.toolTip = "\(coordinator.i18n.t(.startRecording))/\(coordinator.i18n.t(.stopRecording))"
            if let img = NSImage(systemSymbolName: "record.circle", accessibilityDescription: label) {
                img.isTemplate = true
                item.image = img
            }
            let target = RecordingToolbarItemTarget(
                coordinator: coordinator,
                label: label
            )
            objc_setAssociatedObject(item, "recordingTarget", target, .OBJC_ASSOCIATION_RETAIN)
            item.target = target; item.action = #selector(RecordingToolbarItemTarget.invoke)
            item.menuFormRepresentation = NSMenuItem(title: label, action: #selector(RecordingToolbarItemTarget.invoke), keyEquivalent: "")
            item.menuFormRepresentation?.target = target
            if let mImg = NSImage(systemSymbolName: "record.circle", accessibilityDescription: label) {
                mImg.isTemplate = true
                item.menuFormRepresentation?.image = mImg
            }
            return item

        case .jumpHosts:
            return makeItem(
                id: itemIdentifier,
                label: coordinator.i18n.t(.jumpHosts),
                icon: "arrow.triangle.swap"
            ) { [weak self] in
                self?.coordinator.showJumpHosts = true
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

    private func makeImportMenuItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let label = coordinator.i18n.t(.importSessions)
        // Single-click auto-detect (SSH config + Tabby), no dropdown per UX feedback
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        if let img = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: label) {
            img.isTemplate = true
            item.image = img
        }
        let target = ImportMenuTarget(coordinator: coordinator)
        objc_setAssociatedObject(item, "importTarget", target, .OBJC_ASSOCIATION_RETAIN)
        item.target = target
        item.action = #selector(ImportMenuTarget.importUnified)
        // Keep menu for File menu parity (optional), but toolbar is single-click
        let menu = NSMenu()
        let sshTitle = coordinator.i18n.t(.importSSHConfig)
        let tabbyTitle = coordinator.i18n.t(.importTabby)
        let sshItem = NSMenuItem(title: sshTitle, action: #selector(ImportMenuTarget.importSSH), keyEquivalent: "")
        let tabbyItem = NSMenuItem(title: tabbyTitle, action: #selector(ImportMenuTarget.importTabby), keyEquivalent: "")
        // unified single-click: no dropdown menu on toolbar item itself
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

@MainActor
private final class ImportMenuTarget: NSObject {
    private let coordinator: ToolbarCoordinator
    init(coordinator: ToolbarCoordinator) { self.coordinator = coordinator; super.init() }
    @objc func importUnified() { coordinator.showUnifiedImport = true }
    @objc func importSSH() { coordinator.showSSHConfigImport = true }
    @objc func importTabby() { coordinator.showTabbyImport = true }
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

@MainActor
private final class RecordingToolbarItemTarget: NSObject, NSToolbarItemValidation {
    private let coordinator: ToolbarCoordinator
    private let label: String
    init(coordinator: ToolbarCoordinator, label: String) { self.coordinator = coordinator; self.label = label; super.init() }

    @objc func invoke() {
        Task { @MainActor in await toggle() }
    }
    @objc func showList() {
        coordinator.showRecordings = true
        // fallback window if no sheet observer — match SFTP/workspace window style
        let view = NavigationStack { RecordingListView().environment(coordinator.i18n) }
        let hostingView = NSHostingView(rootView: view)
        hostingView.autoresizingMask = [.width, .height]
        let contentSize = NSSize(width: 600, height: 400)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 520, height: 300)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setContentSize(contentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggle() async {
        guard let tab = coordinator.sessionManager.activeTab else {
            coordinator.showRecordings = true; return
        }
        let paneID: UUID = FocusManager.shared.focusedPaneID ?? tab.activePaneID ?? tab.layout.activePaneID
        guard let pane = tab.layout.findPane(id: paneID) else {
            coordinator.showRecordings = true; return
        }
        let isRec = await SessionRecordingService.shared.isRecording(paneID: paneID)
        if isRec {
            await SessionRecordingService.shared.stop(paneID: paneID)
            pane.ptySession?.recordingPaneID = nil
        } else {
            do {
                _ = try await SessionRecordingService.shared.start(host: tab.hostItem.name, tabID: tab.id, paneID: paneID, cols: 80, rows: 24)
                pane.ptySession?.recordingPaneID = paneID
            } catch {
                coordinator.sessionManager.lastError = error.localizedDescription; coordinator.sessionManager.showError = true
            }
        }
    }

    nonisolated func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        MainActor.assumeIsolated {
            // optimistic: check if any pane is recording, tint red
            var anyRecording = false
            for tab in coordinator.sessionManager.tabs {
                for pid in tab.paneIDs {
                    // synchronous check would need await, so we use pane's ptySession flag as proxy
                    if tab.layout.findPane(id: pid)?.ptySession?.recordingPaneID != nil { anyRecording = true; break }
                }
            }
            let symbol = NSImage(systemSymbolName: anyRecording ? "record.circle.fill" : "record.circle", accessibilityDescription: label)
            item.image = anyRecording ? symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) : symbol
            item.label = anyRecording ? "● \(coordinator.i18n.t(.rec))" : label
            item.toolTip = anyRecording ? coordinator.i18n.t(.stopRecording) : coordinator.i18n.t(.startRecording)
        }
        return true
    }
}
