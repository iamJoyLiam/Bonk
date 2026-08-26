import AppKit
import os.log
import SwiftData
import SwiftUI

@main
struct BonkApp: App {
    @NSApplicationDelegateAdaptor(BonkAppDelegate.self) private var appDelegate
    @State private var i18n = I18n()
    @State private var updater = UpdaterManager()
    @State private var shortcutManager = ShortcutManager.shared
    #if os(macOS)
        @State private var quakeController = QuakeController()
    #endif

    init() {
        let saved = UserDefaults.standard.string(forKey: "app_language") ?? "system"
        if saved == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([saved], forKey: "AppleLanguages")
        }
    }

    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            HostItem.self, UserPreferences.self, Credential.self, HostGroup.self,
            AIConversationRecord.self, AIMessageRecord.self, AIProviderRecord.self,
            Snippet.self, PortForward.self, JumpHost.self, InlineSuggestionRecord.self,
            SSHBackendProfile.self, TriggerRule.self,
        ])
        // AGENTS.md: never change storeName — always use default. DEBUG uses in-memory store to avoid touching real DB (Xcode runs).
        #if DEBUG
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        #else
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        #endif
        func deleteDevStore() {
            let fileManager = FileManager.default
            if let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let base = url.appendingPathComponent("Bonk-Dev.store")
                for ext in ["", "-shm", "-wal"] {
                    let file = URL(fileURLWithPath: base.path + ext)
                    try? fileManager.removeItem(at: file)
                }
            }
        }
        func isSchemaMismatch(_ error: Error) -> Bool {
            let msg = error.localizedDescription + " " + String(describing: error)
            return msg.contains("no such table") || msg.contains("no such column")
                || msg.contains("ZSSHBACKENDPROFILE") || msg.contains("ZFORCECOMPATIBILITY")
                || msg.contains("ZTRIGGERRULE") || msg.contains("TriggerRule")
        }
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            // Verify tables exist — ModelContainer init is lazy; first fetch reveals missing table
            do {
                let ctx = ModelContext(container)
                _ = try ctx.fetch(FetchDescriptor<SSHBackendProfile>())
                _ = try ctx.fetch(FetchDescriptor<HostItem>())
                _ = try ctx.fetch(FetchDescriptor<TriggerRule>())
            } catch {
                if isSchemaMismatch(error) {
                    #if DEBUG
                        Log.app.error("Schema mismatch detected after init, deleting Dev store and retrying: \(error)")
                        deleteDevStore()
                        return try ModelContainer(for: schema, configurations: [config])
                    #else
                        Log.app.error("Schema mismatch detected after init: \(error) — needs migration, not deletion")
                    #endif
                }
                throw error
            }
            return container
        } catch {
            #if DEBUG
                if isSchemaMismatch(error) {
                    Log.app.error("ModelContainer missing table/column, deleting Dev store and retrying: \(error)")
                    deleteDevStore()
                    do {
                        return try ModelContainer(for: schema, configurations: [config])
                    } catch {
                        Log.app.error("Retry failed: \(error)")
                    }
                }
            #endif
            Log.app.error("ModelContainer failed: \(error.localizedDescription)")
            fatalError("Database initialization failed: \(error)")
        }
    }()

    var body: some Scene {
        #if os(macOS)
            Settings {
                SettingsContainerView(quakeController: quakeController).environment(i18n)
            }
            .modelContainer(Self.sharedModelContainer)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button { NSApp.orderFrontStandardAboutPanel(nil) } label: {
                        Label(i18n.t(.about) + " Bonk", systemImage: "info.circle")
                    }
                    Divider()
                    Button { updater.checkForUpdates() } label: {
                        Label(i18n.t(.checkUpdates), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                }
                FileMenuCommands(i18n: i18n, shortcutManager: shortcutManager)
                EditMenuCommands(i18n: i18n, shortcutManager: shortcutManager)
                ViewMenuCommands(i18n: i18n, shortcutManager: shortcutManager)
                ConnectionMenuCommands(i18n: i18n, shortcutManager: shortcutManager)
                AIMenuCommands(i18n: i18n, shortcutManager: shortcutManager)
                TeamMenuCommands(i18n: i18n)
            }
        #endif
    }
}

// MARK: - Menu Commands (Direct — not FocusedValue; main window is AppKit-owned)

// AppKit-owned main window (BonkAppDelegate) hosts SwiftUI via NSHostingController,
// so FocusedValue providers in ContentView are not resolved by SwiftUI's Scene
// focus system (Settings is the only SwiftUI Scene). Commands that depend on
// @FocusedValue appear disabled. These commands call the shared managers directly
// and are always enabled — the focused providers remain as a fallback.

#if os(macOS)
    private struct FileMenuCommands: Commands {
        let i18n: I18n
        let shortcutManager: ShortcutManager
        var body: some Commands {
            let newTerminalShortcut = shortcutManager.shortcut(for: .newTerminal)
            let closeTabShortcut = shortcutManager.shortcut(for: .closeTab)
            CommandGroup(after: .newItem) {
                Button(i18n.t(.newTerminal)) {
                    Task { @MainActor in
                        if let coordinator = BonkAppDelegate.shared?.coordinator { coordinator.showAddHostSheet = true }
                        else { NotificationCenter.default.post(name: .terminalNewTab, object: nil) }
                    }
                }
                .keyboardShortcut(newTerminalShortcut.key, modifiers: newTerminalShortcut.modifiers)
                Button(i18n.t(.closeTab)) {
                    Task { @MainActor in
                        if let sessionManager = BonkAppDelegate.shared?.sessionManager, let id = sessionManager.activeTabID {
                            await sessionManager.closeTab(id)
                        } else {
                            // Fallback via focused provider if AppKit bridge not ready (e.g. preview)
                            NotificationCenter.default.post(name: .init("BonkCloseTab"), object: nil)
                        }
                    }
                }
                .keyboardShortcut(closeTabShortcut.key, modifiers: closeTabShortcut.modifiers)
                Divider()
                Button(i18n.t(.workspaces) + "...") {
                    Task { @MainActor in BonkAppDelegate.shared?.coordinator?.showWorkspaces = true }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button(i18n.t(.importSessions)) {
                    Task { @MainActor in BonkAppDelegate.shared?.coordinator?.showUnifiedImport = true }
                }
            }
        }
    }

    private struct EditMenuCommands: Commands {
        let i18n: I18n
        let shortcutManager: ShortcutManager
        var body: some Commands {
            let findShortcut = shortcutManager.shortcut(for: .find)
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(i18n.t(.find)) {
                    Task { @MainActor in
                        AppStore.shared.toggleSearch()
                        // ContentView keeps a local @State showTerminalSearch; keep it in sync via notification
                        NotificationCenter.default.post(name: .init("BonkToggleFind"), object: nil, userInfo: ["show": AppStore.shared.showSearch])
                    }
                }
                .keyboardShortcut(findShortcut.key, modifiers: findShortcut.modifiers)
            }
        }
    }

    private struct ViewMenuCommands: Commands {
        let i18n: I18n
        let shortcutManager: ShortcutManager
        var body: some Commands {
            let splitHorizontalShortcut = shortcutManager.shortcut(for: .splitHorizontal)
            let splitVerticalShortcut = shortcutManager.shortcut(for: .splitVertical)
            let closePaneShortcut = shortcutManager.shortcut(for: .closePane)
            let sftpBrowserShortcut = shortcutManager.shortcut(for: .sftpBrowser)
            CommandMenu(i18n.t(.menuView)) {
                Button(i18n.t(.splitHorizontal)) {
                    Task { @MainActor in BonkAppDelegate.shared?.sessionManager?.splitHorizontal() }
                }
                .keyboardShortcut(splitHorizontalShortcut.key, modifiers: splitHorizontalShortcut.modifiers)
                Button(i18n.t(.splitVertical)) {
                    Task { @MainActor in BonkAppDelegate.shared?.sessionManager?.splitVertical() }
                }
                .keyboardShortcut(splitVerticalShortcut.key, modifiers: splitVerticalShortcut.modifiers)
                Button(i18n.t(.closePane)) {
                    Task { @MainActor in BonkAppDelegate.shared?.sessionManager?.closePane() }
                }
                .keyboardShortcut(closePaneShortcut.key, modifiers: closePaneShortcut.modifiers)
                Divider()
                Button(i18n.t(.sftpBrowser)) {
                    Task { @MainActor in
                        if let workspace = BonkAppDelegate.shared?.workspace { workspace.toggleSFTPWindow() }
                        else { NotificationCenter.default.post(name: .toggleSFTP, object: nil) }
                    }
                }
                .keyboardShortcut(sftpBrowserShortcut.key, modifiers: sftpBrowserShortcut.modifiers)
                Divider()
                Button(i18n.t(.recording)) {
                    Task { @MainActor in await ViewMenuCommands.toggleRecording(coordinator: BonkAppDelegate.shared?.coordinator) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(i18n.t(.showRecordings)) {
                    Task { @MainActor in BonkAppDelegate.shared?.coordinator?.showRecordings = true }
                }
                Divider()
                Menu(i18n.t(.theme)) {
                    Button(i18n.t(.system)) { Task { @MainActor in TerminalThemeManager.shared.setActive("system") } }
                    ForEach(ThemeRegistry.all, id: \.id) { theme in
                        Button(theme.name) { Task { @MainActor in TerminalThemeManager.shared.setActive(theme.id) } }
                    }
                }
            }
        }
        @MainActor static func toggleRecording(coordinator: ToolbarCoordinator?) async {
            guard let coordinator, let tab = coordinator.sessionManager.activeTab else { return }
            let paneID: UUID = FocusManager.shared.focusedPaneID ?? tab.activePaneID ?? tab.layout.activePaneID
            guard let pane = tab.layout.findPane(id: paneID) else { return }
            let isRec = await SessionRecordingService.shared.isRecording(paneID: paneID)
            if isRec {
                await SessionRecordingService.shared.stop(paneID: paneID)
                pane.ptySession?.recordingPaneID = nil
            } else {
                _ = try? await SessionRecordingService.shared.start(host: tab.hostItem.name, tabID: tab.id, paneID: paneID)
                pane.ptySession?.recordingPaneID = paneID
            }
        }
    }

    private struct ConnectionMenuCommands: Commands {
        let i18n: I18n
        let shortcutManager: ShortcutManager
        var body: some Commands {
            let reconnectShortcut = shortcutManager.shortcut(for: .reconnect)
            CommandMenu(i18n.t(.menuConnection)) {
                Button(i18n.t(.connect)) {
                    Task { @MainActor in BonkAppDelegate.shared?.coordinator?.showAddHostSheet = true }
                }
                Button(i18n.t(.disconnect)) {
                    Task { @MainActor in
                        if let sessionManager = BonkAppDelegate.shared?.sessionManager, let id = sessionManager.activeTabID { await sessionManager.disconnectTab(id) }
                    }
                }
                Button(i18n.t(.reconnect)) {
                    Task { @MainActor in
                        if let sessionManager = BonkAppDelegate.shared?.sessionManager, let id = sessionManager.activeTabID { await sessionManager.reconnectTab(id) }
                    }
                }
                .keyboardShortcut(reconnectShortcut.key, modifiers: reconnectShortcut.modifiers)
                Divider()
                Button(i18n.t(.snippets)) {
                    Task { @MainActor in
                        if let coordinator = BonkAppDelegate.shared?.coordinator { coordinator.showSnippets() }
                        else { NotificationCenter.default.post(name: .init("BonkShowSnippets"), object: nil) }
                    }
                }
                Button(i18n.t(.commandHistory)) {
                    Task { @MainActor in
                        if let workspace = BonkAppDelegate.shared?.workspace {
                            workspace.snippetsHistoryTab = .history
                            workspace.activeRightPanel = .snippetsHistory
                        }
                    }
                }
                Divider()
                Button(i18n.t(.portForwarding)) {
                    Task { @MainActor in BonkAppDelegate.shared?.workspace?.isPortForwardingPresented = true }
                }
                Button(i18n.t(.serialPort)) {
                    Task { @MainActor in BonkAppDelegate.shared?.workspace?.isSerialPortPresented = true }
                }
            }
        }
    }

    private struct AIMenuCommands: Commands {
        let i18n: I18n
        let shortcutManager: ShortcutManager
        var body: some Commands {
            let aiAssistantShortcut = shortcutManager.shortcut(for: .aiAssistant)
            CommandMenu(i18n.t(.menuAI)) {
                Button(i18n.t(.aiAssistant)) {
                    Task { @MainActor in
                        if let workspace = BonkAppDelegate.shared?.workspace { workspace.toggleRightPanel(.ai) }
                        else { NotificationCenter.default.post(name: .toggleAIChat, object: nil) }
                    }
                }
                .keyboardShortcut(aiAssistantShortcut.key, modifiers: aiAssistantShortcut.modifiers)
            }
        }
    }

    private struct TeamMenuCommands: Commands {
        let i18n: I18n
        var body: some Commands {
            CommandMenu(i18n.t(.team)) {
                Button(i18n.t(.team)) {
                    Task { @MainActor in BonkAppDelegate.shared?.coordinator?.showTeam = true }
                }
                Button(i18n.t(.liveTerminal)) {
                    Task { @MainActor in
                        if TeamRelay.shared.isConnected, let workspace = BonkAppDelegate.shared?.workspace {
                            workspace.toggleTeamWindow()
                        } else {
                            BonkAppDelegate.shared?.coordinator?.showTeam = true
                        }
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
#endif

#if os(macOS)
    private struct SettingsContainerView: View {
        @Query private var allPreferences: [UserPreferences]
        @Environment(\.modelContext) private var modelContext
        @Bindable var quakeController: QuakeController

        private var preferences: UserPreferences {
            allPreferences.first ?? UserPreferences()
        }

        private func ensurePreferences() {
            if allPreferences.isEmpty { modelContext.insert(UserPreferences()) }
        }

        var body: some View {
            SettingsView(preferences: preferences, quakeController: quakeController)
                .onAppear { ensurePreferences() }
        }
    }
#endif
