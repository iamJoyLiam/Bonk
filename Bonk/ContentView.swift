import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query private var allPreferences: [UserPreferences]
    @StateObject private var themeManager = TerminalThemeManager.shared

    @Bindable private var appStore = AppStore.shared
    #if os(macOS)
        @State private var quakeController = QuakeController()
        @State private var showTerminalSearch = false
        @State private var sftpWindow: NSWindow?
        @State private var sftpWindowDelegate: SFTPWindowDelegate?
        @State private var teamWindow: NSWindow?
        @State private var teamWindowDelegate: TeamWindowDelegate?
        @Environment(WorkspaceManager.self) private var workspace
        @Bindable var sessionManager: SessionManager
        @Bindable var toolbarCoordinator: ToolbarCoordinator
        @ObservedObject private var teamRelay = TeamRelay.shared
    #endif

    private var preferences: UserPreferences {
        allPreferences.first ?? UserPreferences()
    }

    private func ensurePreferences() {
        if allPreferences.isEmpty {
            modelContext.insert(UserPreferences())
        }
    }

    private var colorScheme: TerminalColorScheme {
        themeManager.resolve()
    }

    #if os(macOS)
        private var workspaceBindable: Bindable<WorkspaceManager> {
            Bindable(workspace)
        }

        private var controlRevokedBinding: Binding<Bool> {
            Binding(
                get: {
                    if workspace.isTeamWindowOpen {
                        return false
                    }
                    return teamRelay.controlRevokedNotice != nil
                },
                set: {
                    if !$0 {
                        teamRelay.controlRevokedNotice = nil
                    }
                }
            )
        }

        private var peerDisconnectedBinding: Binding<Bool> {
            Binding(
                get: { teamRelay.peerDisconnectedNotice != nil },
                set: {
                    if !$0 {
                        teamRelay.peerDisconnectedNotice = nil
                    }
                }
            )
        }
    #endif

    var body: some View {
        Group {
            #if os(macOS)
                macOSLayout
            #else
                iOSLayout
            #endif
        }
        .environment(\.locale, Locale(identifier: i18n.lang))
        #if os(macOS)
            .environment(workspace)
        #endif
            .onAppear {
                ensurePreferences()
                AIDataMigration.migrateIfNeeded(context: modelContext)
                sessionManager.setModelContext(modelContext)
                CommandIntelligenceAssembly.configure(modelContext: modelContext)
                sessionManager.broadcastManager = workspace.broadcastManager
                ServerResourceMonitor.shared.start(sessionManager: sessionManager)
                TerminalViewCache.shared.configureMemoryPressure {
                    sessionManager.activeTabID
                }
                TriggerManager.shared.configure(modelContext: modelContext)
                if preferences.autoSyncSSHConfig == true {
                    SSHConfigWatcher.shared.start()
                }
                // Sync coordinator with actual state
                toolbarCoordinator.workspace = workspace
                toolbarCoordinator.sessionManager = sessionManager
                toolbarCoordinator.i18n = i18n
                toolbarCoordinator.modelContext = modelContext
                // Setup Quake terminal - reuse main container (AGENTS.md: never change storeName, single container)
                setupQuakeTerminal(with: quakeController, sessionManager: sessionManager, i18n: i18n, modelContainer: modelContext.container)
            }
            .alert(i18n.t(.connectionError), isPresented: $sessionManager.showError) {
                Button(i18n.t(.ok)) {}
            } message: {
                Text(sessionManager.lastError ?? i18n.t(.unknownError))
            }
            .modifier(MenuActionsModifier(
                sessionManager: sessionManager,
                workspace: workspace,
                appStore: appStore,
                themeManager: themeManager,
                toolbarCoordinator: toolbarCoordinator,
                showTerminalSearch: $showTerminalSearch
            ))
    }

    // MARK: - macOS Layout (detail pane; sidebar/inspector live in

    // MainSplitViewController)

    #if os(macOS)
        private var macOSLayout: some View {
            TerminalTabView(
                sessionManager: sessionManager,
                colorScheme: colorScheme,
                cursorStyle: themeManager.cursorStyle,
                cursorBlink: themeManager.cursorBlink,
                showSearch: $showTerminalSearch
            )
            .background(colorScheme.isTransparent ? Color.clear : Color(nsColor: colorScheme.background.nsColor))
            .clipped()
            // Split from one giant chain into separate checking units (Xcode 27
            // cannot type-check the full chain as a single expression).
            // Ordering and behavior are unchanged.
            .modifier(TerminalSyncModifiers(
                workspace: workspace,
                toolbarCoordinator: toolbarCoordinator,
                teamRelay: teamRelay,
                appStore: appStore,
                sessionManager: sessionManager,
                showTerminalSearch: $showTerminalSearch,
                autoSyncSSHConfig: preferences.autoSyncSSHConfig,
                onSFTPWindowChange: { $0 ? openSFTPWindow() : closeSFTPWindow() },
                onTeamWindowChange: { $0 ? openTeamWindow() : closeTeamWindow() },
                onNewTab: handleNewTabShortcut
            ))
            .modifier(TeamAlertModifiers(
                i18n: i18n,
                teamRelay: teamRelay,
                controlRevoked: controlRevokedBinding,
                peerDisconnected: peerDisconnectedBinding,
                onMergeShareHosts: importSharedHosts
            ))
            .modifier(TerminalSheetModifiers(
                toolbarCoordinator: toolbarCoordinator,
                workspace: workspace,
                sessionManager: sessionManager,
                i18n: i18n,
                defaultPort: preferences.defaultPort,
                modelContext: modelContext
            ))
            // (alerts + sheets now live in TeamAlertModifiers / TerminalSheetModifiers)
        }
    #endif

    // MARK: - SFTP Window

    @State private var lastNewTabAt = Date.distantPast

    private func handleNewTabShortcut() {
        let now = Date()
        guard now.timeIntervalSince(lastNewTabAt) > 0.2 else { return }
        lastNewTabAt = now
        toolbarCoordinator.showAddHostSheet = true
    }

    private func openSFTPWindow() {
        #if os(macOS)
            if let window = sftpWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                return
            }

            let contentSize = NSSize(width: 1000, height: 650)
            let minimumContentSize = NSSize(width: 800, height: 500)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.contentMinSize = minimumContentSize
            window.title = i18n.t(.sftpBrowser)
            window.isReleasedWhenClosed = false
            let hostingView = NSHostingView(
                rootView: SFTPWindowView(sessionManager: sessionManager)
                    .environment(i18n)
                    .environment(workspace)
                    .modelContext(modelContext)
            )
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            window.setContentSize(contentSize)
            window.center()
            window.makeKeyAndOrderFront(nil)
            let delegate = SFTPWindowDelegate {
                sftpWindow = nil
                sftpWindowDelegate = nil
                workspace.isSFTPWindowOpen = false
            }
            sftpWindowDelegate = delegate
            window.delegate = delegate
            sftpWindow = window
        #endif
    }

    private func closeSFTPWindow() {
        #if os(macOS)
            guard let window = sftpWindow else { return }
            window.close()
            sftpWindow = nil
            sftpWindowDelegate = nil
        #endif
    }

    private func openTeamWindow() {
        #if os(macOS)
            if let window = teamWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let contentSize = NSSize(width: 860, height: 620)
            let minimumContentSize = NSSize(width: 640, height: 480)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.contentMinSize = minimumContentSize
            window.title = i18n.t(.liveTerminal)
            window.isReleasedWhenClosed = false
            window.titleVisibility = .visible
            let hostingView = NSHostingView(
                rootView: TeamLiveWindowView(relay: TeamRelay.shared)
                    .environment(i18n)
                    .environment(workspace)
                    .modelContext(modelContext)
            )
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            window.setContentSize(contentSize)
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let delegate = TeamWindowDelegate {
                teamWindow = nil
                teamWindowDelegate = nil
                workspace.isTeamWindowOpen = false
            }
            teamWindowDelegate = delegate
            window.delegate = delegate
            teamWindow = window
        #endif
    }

    private func closeTeamWindow() {
        #if os(macOS)
            guard let window = teamWindow else { return }
            window.close()
            teamWindow = nil
            teamWindowDelegate = nil
        #endif
    }

    private func importSharedHosts(_ hosts: [HostItemExport]) async {
        for exp in hosts {
            // deduplicate by host+port+username
            let exists = (try? modelContext.fetch(FetchDescriptor<HostItem>()))?.contains(where: { $0.host == exp.host && $0.port == exp.port && $0.username == exp.username }) ?? false
            if exists {
                continue
            }
            let authType = AuthType(rawValue: exp.authType) ?? .password
            let host = HostItem(name: exp.name, host: exp.host, port: exp.port, username: exp.username, authType: authType)
            if let credExp = exp.credential, let secret = credExp.secret, !secret.isEmpty {
                // SecureEnclave cannot be shared
                if authType == .secureEnclave { /* skip secret */ } else {
                    let type = CredentialType(rawValue: credExp.type) ?? .password
                    if type != .apiKey {
                        let cred = Credential(name: credExp.name, type: type, username: credExp.username)
                        cred.storeSecret(secret)
                        modelContext.insert(cred)
                        host.credentialRef = cred
                    }
                }
            }
            if let secret = exp.credential?.secret, exp.credential == nil, !secret.isEmpty {
                if authType == .password {
                    host.storePassword(secret)
                } else if authType == .privateKey {
                    host.storePrivateKey(secret)
                }
            }
            modelContext.insert(host)
        }
        try? modelContext.save()
    }

    // MARK: - iOS Layout

    private var iOSLayout: some View {
        NavigationStack {
            HostListView(sessionManager: sessionManager, defaultPort: preferences.defaultPort)
                .navigationTitle("Bonk")
                .navigationDestination(for: UUID.self) { tabID in
                    if let tab = sessionManager.tabs.first(where: { $0.id == tabID }) {
                        iOSTerminalDetail(tab)
                    }
                }
        }
    }

    private func iOSTerminalDetail(_ tab: TerminalTab) -> some View {
        TerminalTabContentView(
            tab: tab,
            colorScheme: colorScheme,
            fontSize: preferences.fontSize,
            fontFamily: preferences.fontFamily,
            lineHeight: preferences.lineHeight,
            scrollbackLines: preferences.scrollbackLines,
            cursorStyle: themeManager.cursorStyle,
            cursorBlink: themeManager.cursorBlink,
            copyOnSelect: preferences.copyOnSelect,
            scrollSensitivity: preferences.scrollSensitivity ?? 1.0,
            onSend: { data in Task { try? await sessionManager.sendInput(data, to: tab.id) } },
            onResize: { cols, rows in Task { try? await sessionManager.resizePTY(cols: cols, rows: rows, tabID: tab.id) } },
            onTitleChange: { title in
                Task { @MainActor in sessionManager.updateTabTitle(title, tabID: tab.id) }
            },
            onReconnect: { Task { await sessionManager.reconnectTab(tab.id) } }
        )
        .navigationTitle(tab.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { Task { await sessionManager.reconnectTab(tab.id) } } label: {
                            Label(i18n.t(.reconnect), systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) { Task { await sessionManager.closeTab(tab.id) } } label: {
                            Label(i18n.t(.disconnect), systemImage: "bolt.slash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
    }
}

// MARK: - Menu Actions Modifier

#if os(macOS)
    private struct MenuActionsModifier: ViewModifier {
        let sessionManager: SessionManager
        let workspace: WorkspaceManager
        let appStore: AppStore
        let themeManager: TerminalThemeManager
        let toolbarCoordinator: ToolbarCoordinator
        @Binding var showTerminalSearch: Bool

        func body(content: Content) -> some View {
            content
                .modifier(SessionMenuActions(sessionManager: sessionManager, toolbarCoordinator: toolbarCoordinator))
                .modifier(WorkspaceMenuActions(workspace: workspace, toolbarCoordinator: toolbarCoordinator))
                .modifier(AppMenuActions(appStore: appStore, themeManager: themeManager, showTerminalSearch: $showTerminalSearch))
        }
    }

    private struct SessionMenuActions: ViewModifier {
        let sessionManager: SessionManager
        let toolbarCoordinator: ToolbarCoordinator

        func body(content: Content) -> some View {
            content
                .focusedSceneValue(\.menuCloseTab) {
                    if let id = sessionManager.activeTabID {
                        Task { await sessionManager.closeTab(id) }
                    }
                }
                .focusedSceneValue(\.menuNewTerminal) { toolbarCoordinator.showAddHostSheet = true }
                .focusedSceneValue(\.menuDisconnect) {
                    if let id = sessionManager.activeTabID {
                        Task { await sessionManager.disconnectTab(id) }
                    }
                }
                .focusedSceneValue(\.menuReconnect) {
                    if let id = sessionManager.activeTabID {
                        Task { await sessionManager.reconnectTab(id) }
                    }
                }
                .focusedSceneValue(\.menuSplitHorizontal) { sessionManager.splitHorizontal() }
                .focusedSceneValue(\.menuSplitVertical) { sessionManager.splitVertical() }
                .focusedSceneValue(\.menuClosePane) { sessionManager.closePane() }
        }
    }

    private struct WorkspaceMenuActions: ViewModifier {
        let workspace: WorkspaceManager
        let toolbarCoordinator: ToolbarCoordinator

        func body(content: Content) -> some View {
            content
                .focusedSceneValue(\.menuToggleSFTP) {
                    NotificationCenter.default.post(name: .toggleSFTP, object: nil)
                }
                .focusedSceneValue(\.menuToggleAITerminal) {
                    NotificationCenter.default.post(name: .toggleAIChat, object: nil)
                }
                .focusedSceneValue(\.menuShowSerialPort) { workspace.isSerialPortPresented = true }
                .focusedSceneValue(\.menuShowSnippets) {
                    toolbarCoordinator.showSnippets()
                }
                .focusedSceneValue(\.menuShowPortForwarding) { workspace.isPortForwardingPresented = true }
                .focusedSceneValue(\.menuShowCommandHistory) {
                    workspace.snippetsHistoryTab = .history
                    workspace.activeRightPanel = .snippetsHistory
                }
                .focusedSceneValue(\.menuShowWorkspaces) { toolbarCoordinator.showWorkspaces = true }
        }
    }

    private struct AppMenuActions: ViewModifier {
        let appStore: AppStore
        let themeManager: TerminalThemeManager
        @Binding var showTerminalSearch: Bool

        func body(content: Content) -> some View {
            content
                .focusedSceneValue(\.menuChangeTheme) { themeID in themeManager.setActive(themeID) }
                .focusedSceneValue(\.menuFind) {
                    appStore.toggleSearch()
                    showTerminalSearch = appStore.showSearch
                }
        }
    }
#endif

// MARK: - Quake Terminal

#if os(macOS)
    private func setupQuakeTerminal(with controller: QuakeController, sessionManager: SessionManager, i18n: I18n, modelContainer: ModelContainer) {
        DispatchQueue.main.async {
            // Create a real terminal view for Quake with shared model container
            let quakeView = QuakeTerminalView(sessionManager: sessionManager)
                .environment(i18n)
                .modelContainer(modelContainer)
            let hostingView = NSHostingView(rootView: quakeView)
            hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)

            controller.setup(contentView: hostingView)
            controller.focusManager.alternateScreenProvider = { @MainActor [weak sessionManager] in
                guard let sessionManager, let tab = sessionManager.activeTab else { return false }
                return TerminalViewCache.shared.isAnyPaneAlternate(paneIDs: tab.paneIDs)
            }
        }
    }
#endif

// MARK: - Quake Terminal View

#if os(macOS)
    /// Terminal view for Quake dropdown window.
    /// macOS 26 style: modern, clean, with rounded corners and materials.
    struct QuakeTerminalView: View {
        @Environment(I18n.self) var i18n
        @StateObject private var themeManager = TerminalThemeManager.shared
        let sessionManager: SessionManager

        private var colorScheme: TerminalColorScheme {
            themeManager.resolve()
        }

        var body: some View {
            VStack(spacing: 0) {
                // Header with tab info
                HStack {
                    if let tab = sessionManager.activeTab {
                        Circle()
                            .fill(statusColor(for: tab))
                            .frame(width: AppStyle.statusDotMedium, height: AppStyle.statusDotMedium)
                            .shadow(color: statusColor(for: tab).opacity(AppStyle.opacityDisabled), radius: 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(tab.title)
                                .font(.system(size: AppStyle.fontBody, weight: .semibold))
                            Text(tab.hostItem.host)
                                .font(.system(size: AppStyle.fontCaption))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: AppStyle.fontMedium))
                            .foregroundStyle(.secondary)

                        Text(i18n.t(.noActiveSession))
                            .font(.system(size: AppStyle.fontBody, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, AppStyle.spacingXL)
                .padding(.vertical, AppStyle.spacingML)
                .background(.ultraThinMaterial)

                // Terminal content - shares the same tab
                if let tab = sessionManager.activeTab {
                    TerminalTabContentView(
                        tab: tab,
                        colorScheme: colorScheme,
                        fontSize: 13,
                        fontFamily: "SF Mono",
                        lineHeight: 1.2,
                        scrollbackLines: 10000,
                        cursorStyle: "block",
                        cursorBlink: true,
                        copyOnSelect: true,
                        scrollSensitivity: 1.0,
                        onSend: { data in
                            Task {
                                try? await sessionManager.sendInput(data, to: tab.id)
                            }
                        },
                        onResize: nil,
                        onTitleChange: nil,
                        onReconnect: nil
                    )
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "terminal")
                            .font(.system(size: AppStyle.fontDisplay))
                            .foregroundStyle(.tertiary)
                        Text(i18n.t(.noActiveSession))
                            .font(.system(size: AppStyle.fontMedium, weight: .medium))
                        Text(i18n.t(.connectFromMainWindow))
                            .font(.system(size: AppStyle.fontBody))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppStyle.tabCornerRadius, style: .continuous))
            .frame(minWidth: AppStyle.quakeMinWidth, minHeight: AppStyle.quickConnectWidth)
        }

        private func statusColor(for tab: TerminalTab) -> Color {
            switch tab.session?.connectionState {
            case .connected: .green
            case .connecting, .reconnecting: .yellow
            default: .red
            }
        }
    }
#endif

// MARK: - SFTP Window Delegate

#if os(macOS)
    private final class SFTPWindowDelegate: NSObject, NSWindowDelegate {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_: Notification) {
            onClose()
        }
    }

    private final class TeamWindowDelegate: NSObject, NSWindowDelegate {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_: Notification) {
            onClose()
        }
    }
#endif
