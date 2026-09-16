//
//  ContentView+Modifiers.swift
//  Bonk
//
//  Modifier groups extracted from ContentView.macOSLayout.
//
//  Why this file exists: macOSLayout used to be a single view-builder chain
//  (terminal + ~10 onChange/onReceive + 5 alerts + 12 sheets). Xcode 27's
//  type checker cannot solve that as one expression
//  ("unable to type-check in reasonable time"). Each modifier body below is
//  its own checking unit, and the inline Binding(get:set:) closures — the
//  heaviest inference nodes — are hoisted into standalone computed
//  properties. Behavior and ordering are unchanged; this is purely a split.
//
//  macOS-only: these are only used by macOSLayout.
//

#if os(macOS)
    import SwiftData
    import SwiftUI

    // MARK: - Window / Notification Sync

    /// All onChange/onReceive wiring for the main window.
    struct TerminalSyncModifiers: ViewModifier {
        let workspace: WorkspaceManager
        let toolbarCoordinator: ToolbarCoordinator
        let teamRelay: TeamRelay
        let appStore: AppStore
        let sessionManager: SessionManager
        let showTerminalSearch: Binding<Bool>
        let autoSyncSSHConfig: Bool?
        let onSFTPWindowChange: (Bool) -> Void
        let onTeamWindowChange: (Bool) -> Void
        let onNewTab: () -> Void

        func body(content: Content) -> some View {
            content
                // SFTP independent window
                .onChange(of: workspace.isSFTPWindowOpen) { _, isOpen in
                    onSFTPWindowChange(isOpen)
                }
                .onReceive(NotificationCenter.default.publisher(for: .toggleSFTP)) { _ in
                    workspace.toggleSFTPWindow()
                }
                // Team live terminal independent window (like SFTP)
                .onChange(of: workspace.isTeamWindowOpen) { _, isOpen in
                    onTeamWindowChange(isOpen)
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BonkShowTeam"))) { _ in
                    toolbarCoordinator.showTeam = true
                }
                .onChange(of: teamRelay.isConnected) { _, isConnected in
                    syncTeamWindow(isConnected: isConnected, hostPeerID: teamRelay.hostPeerID)
                }
                .onChange(of: teamRelay.hostPeerID) { _, hostPeerID in
                    syncTeamWindow(isConnected: teamRelay.isConnected, hostPeerID: hostPeerID)
                }
                .onReceive(NotificationCenter.default.publisher(for: .terminalNewTab)) { _ in
                    onNewTab()
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BonkToggleFind"))) { note in
                    if let show = note.userInfo?["show"] as? Bool {
                        showTerminalSearch.wrappedValue = show
                    } else {
                        showTerminalSearch.wrappedValue = !showTerminalSearch.wrappedValue
                    }
                    // Keep AppStore in sync if this was triggered elsewhere
                    appStore.showSearch = showTerminalSearch.wrappedValue
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BonkCloseTab"))) { _ in
                    if let id = sessionManager.activeTabID {
                        Task { await sessionManager.closeTab(id) }
                    }
                }
                .onChange(of: autoSyncSSHConfig) { _, isOn in
                    if isOn == true {
                        SSHConfigWatcher.shared.start()
                    } else {
                        SSHConfigWatcher.shared.stop()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: SSHConfigWatcher.didChangeNotification)) { _ in
                    if autoSyncSSHConfig == true {
                        toolbarCoordinator.showUnifiedImport = true
                    }
                }
        }

        private func syncTeamWindow(isConnected: Bool, hostPeerID: UUID?) {
            if isConnected, hostPeerID != nil {
                if !workspace.isTeamWindowOpen {
                    workspace.isTeamWindowOpen = true
                }
                if toolbarCoordinator.showTeam {
                    toolbarCoordinator.showTeam = false
                }
            }
        }
    }

    // MARK: - Team Alerts

    /// All alert popups. The isPresented bindings live outside body so the
    /// checker solves each one separately.
    struct TeamAlertModifiers: ViewModifier {
        let i18n: I18n
        let teamRelay: TeamRelay
        let controlRevoked: Binding<Bool>
        let peerDisconnected: Binding<Bool>
        let onMergeShareHosts: ([HostItemExport]) async -> Void

        private var controlRequestBinding: Binding<Bool> {
            Binding(
                get: { teamRelay.pendingControlRequest != nil },
                set: {
                    if !$0 {
                        teamRelay.pendingControlRequest = nil
                    }
                }
            )
        }

        private var connectionErrorBinding: Binding<Bool> {
            Binding(
                get: {
                    guard teamRelay.lastError != nil else { return false }
                    return !teamRelay.isConnected && !teamRelay.isHosting
                },
                set: {
                    if !$0 {
                        teamRelay.lastError = nil
                    }
                }
            )
        }

        private var pendingShareHostsBinding: Binding<Bool> {
            Binding(
                get: { teamRelay.pendingShareHosts != nil },
                set: {
                    if !$0 {
                        teamRelay.pendingShareHosts = nil
                    }
                }
            )
        }

        func body(content: Content) -> some View {
            content
                // Global Team control request — host sees popup even when Team sheet not open
                .alert(
                    i18n.t(.controlRequestTitle),
                    isPresented: controlRequestBinding
                ) {
                    Button(i18n.t(.allow)) {
                        if let req = teamRelay.pendingControlRequest {
                            teamRelay.grantControl(to: req.peerID)
                        }
                    }
                    Button(i18n.t(.deny), role: .cancel) {
                        teamRelay.pendingControlRequest = nil
                    }
                } message: {
                    if let req = teamRelay.pendingControlRequest {
                        Text(i18n.tr(.controlRequestMessage, args: req.displayName))
                    }
                }
                .alert(
                    i18n.t(.connectionError),
                    isPresented: connectionErrorBinding
                ) {
                    Button(i18n.t(.ok)) { teamRelay.lastError = nil }
                } message: {
                    Text(teamRelay.lastError ?? "")
                }
                .alert(i18n.t(.controlRevokedTitle), isPresented: controlRevoked) {
                    Button(i18n.t(.gotIt)) { teamRelay.controlRevokedNotice = nil }
                } message: {
                    Text(teamRelay.controlRevokedNotice ?? i18n.t(.controlRevokedDefault))
                }
                .alert(i18n.t(.peerDisconnectedTitle), isPresented: peerDisconnected) {
                    Button(i18n.t(.gotIt)) { teamRelay.peerDisconnectedNotice = nil }
                } message: {
                    Text(teamRelay.peerDisconnectedNotice ?? "")
                }
                .alert(
                    i18n.t(.shareHostsTitle),
                    isPresented: pendingShareHostsBinding
                ) {
                    Button(i18n.t(.merge)) {
                        if let hosts = teamRelay.pendingShareHosts {
                            Task { await onMergeShareHosts(hosts) }
                            teamRelay.pendingShareHosts = nil
                        }
                    }
                    Button(i18n.t(.cancel), role: .cancel) { teamRelay.pendingShareHosts = nil }
                } message: {
                    let count = teamRelay.pendingShareHosts?.count ?? 0
                    let separator = i18n.lang.hasPrefix("zh") ? "、" : ", "
                    let names = teamRelay.pendingShareHosts?.map(\.name).joined(separator: separator) ?? ""
                    Text(i18n.tr(.shareHostsMessage, args: count, names))
                }
        }
    }

    // MARK: - Sheets

    /// All sheets presented from the main window.
    struct TerminalSheetModifiers: ViewModifier {
        let toolbarCoordinator: ToolbarCoordinator
        let workspace: WorkspaceManager
        let sessionManager: SessionManager
        let i18n: I18n
        let defaultPort: Int
        let modelContext: ModelContext

        private var toolbar: Bindable<ToolbarCoordinator> {
            Bindable(toolbarCoordinator)
        }

        private var workspaceBinding: Bindable<WorkspaceManager> {
            Bindable(workspace)
        }

        private var sessions: Bindable<SessionManager> {
            Bindable(sessionManager)
        }

        func body(content: Content) -> some View {
            content
                .sheet(isPresented: toolbar.showAddHostSheet) {
                    NavigationStack {
                        AddHostSheet(defaultPort: defaultPort) { host in
                            modelContext.insert(host)
                        }
                        .environment(i18n)
                    }
                }
                .sheet(isPresented: workspaceBinding.isSerialPortPresented) {
                    SerialPortView(isPresented: workspaceBinding.isSerialPortPresented) { config in
                        sessionManager.openSerialTab(config: config)
                    }
                    .environment(i18n)
                }
                .sheet(item: sessions.pendingSerialSave) { config in
                    NavigationStack {
                        SerialPortSaveSheet(config: config)
                            .environment(i18n)
                    }
                }
                .sheet(isPresented: workspaceBinding.isPortForwardingPresented) {
                    PortForwardView(
                        isPresented: workspaceBinding.isPortForwardingPresented,
                        sshService: sessionManager.activeTab?.session?.sshService,
                        session: sessionManager.activeTab?.session
                    )
                    .environment(i18n)
                }
                .sheet(isPresented: toolbar.showUnifiedImport) {
                    UnifiedImportView(modelContext: modelContext)
                }
                .sheet(isPresented: toolbar.showSSHConfigImport) {
                    SSHConfigImportView(modelContext: modelContext)
                }
                .sheet(isPresented: toolbar.showTabbyImport) {
                    TabbyImportView(modelContext: modelContext)
                }
                .sheet(isPresented: toolbar.showKeyGenerator) {
                    SSHKeyGeneratorView()
                }
                .sheet(isPresented: toolbar.showWorkspaces) {
                    WorkspaceListView(sessionManager: sessionManager)
                }
                .sheet(isPresented: toolbar.showRecordings) {
                    NavigationStack {
                        RecordingListView()
                    }
                }
                .sheet(isPresented: toolbar.showJumpHosts) {
                    JumpHostView(isPresented: toolbar.showJumpHosts)
                }
                .sheet(isPresented: toolbar.showTriggers) {
                    NavigationStack { TriggerSettingsView().environment(i18n) }
                }
                .sheet(isPresented: toolbar.showTeam) {
                    TeamSheet(relay: TeamRelay.shared, discovery: TeamDiscoveryService())
                }
        }
    }
#endif
