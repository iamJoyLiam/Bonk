import AppKit
import os.log
import SwiftData
import SwiftUI

@main
struct BonkApp: App {
    @State private var i18n = I18n()
    @State private var updater = UpdaterManager()

    init() {
        let saved = UserDefaults.standard.string(forKey: "app_language") ?? "system"
        if saved == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([saved], forKey: "AppleLanguages")
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            HostItem.self, UserPreferences.self, Credential.self, HostGroup.self,
            AIConversationRecord.self, AIMessageRecord.self, AIProviderRecord.self,
            Snippet.self, SavedSession.self, PortForward.self, JumpHost.self,
        ])
        #if DEBUG
            let config = ModelConfiguration("Bonk-Dev", schema: schema, isStoredInMemoryOnly: false)
        #else
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        #endif
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Migration failed: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(i18n)
                .onAppear {
                    CrashReporter.install()
                    #if os(macOS)
                        TerminalScrollFix.install()
                    #endif
                    applyTheme()
                }
        }
        .modelContainer(sharedModelContainer)
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
            FileMenuCommands(i18n: i18n)
            EditMenuCommands(i18n: i18n)
            ViewMenuCommands(i18n: i18n)
            ConnectionMenuCommands(i18n: i18n)
            AIMenuCommands(i18n: i18n)
        }
        #if os(macOS)
        Settings {
            SettingsContainerView().environment(i18n)
        }
        .modelContainer(sharedModelContainer)
        #endif
    }

    private func applyTheme() {
        let themeID = UserDefaults.standard.string(forKey: "terminalThemeID") ?? "system"
        if themeID == "system" {
            ThemeManager.apply("system")
        } else {
            let isDark = UserDefaults.standard.bool(forKey: "terminalThemeIsDark")
            ThemeManager.apply(isDark ? "dark" : "light")
        }
    }
}

// MARK: - Menu Commands (FocusedValue)

#if os(macOS)
private struct FileMenuCommands: Commands {
    let i18n: I18n
    @FocusedValue(\.menuNewTerminal) private var newTerminal
    @FocusedValue(\.menuCloseTab) private var closeTab
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(i18n.t(.newTerminal)) { newTerminal?() }.keyboardShortcut("t", modifiers: .command)
            Button(i18n.t(.closeTab)) { closeTab?() }.keyboardShortcut("w", modifiers: .command)
        }
    }
}

private struct EditMenuCommands: Commands {
    let i18n: I18n
    @FocusedValue(\.menuFind) private var find
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(i18n.t(.find)) { find?() }.keyboardShortcut("f", modifiers: .command)
        }
    }
}

private struct ViewMenuCommands: Commands {
    let i18n: I18n
    @FocusedValue(\.menuSplitHorizontal) private var splitHorizontal
    @FocusedValue(\.menuSplitVertical) private var splitVertical
    @FocusedValue(\.menuClosePane) private var closePane
    @FocusedValue(\.menuToggleSFTP) private var toggleSFTP
    @FocusedValue(\.menuChangeTheme) private var changeTheme
    var body: some Commands {
        CommandMenu(i18n.t(.menuView)) {
            Button(i18n.t(.splitHorizontal)) { splitHorizontal?() }.keyboardShortcut("d", modifiers: .command)
            Button(i18n.t(.splitVertical)) { splitVertical?() }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button(i18n.t(.closePane)) { closePane?() }.keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button(i18n.t(.sftpBrowser)) { toggleSFTP?() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Menu(i18n.t(.theme)) {
                Button(i18n.t(.system)) { changeTheme?("system") }
                ForEach(ThemeRegistry.all, id: \.id) { theme in Button(theme.name) { changeTheme?(theme.id) } }
            }
        }
    }
}

private struct ConnectionMenuCommands: Commands {
    let i18n: I18n
    @FocusedValue(\.menuConnect) private var connect
    @FocusedValue(\.menuDisconnect) private var disconnect
    @FocusedValue(\.menuReconnect) private var reconnect
    @FocusedValue(\.menuShowSnippets) private var showSnippets
    @FocusedValue(\.menuShowCommandHistory) private var showCommandHistory
    @FocusedValue(\.menuShowPortForwarding) private var showPortForwarding
    @FocusedValue(\.menuShowSerialPort) private var showSerialPort
    var body: some Commands {
        CommandMenu(i18n.t(.menuConnection)) {
            Button(i18n.t(.connect)) { connect?() }
            Button(i18n.t(.disconnect)) { disconnect?() }
            Button(i18n.t(.reconnect)) { reconnect?() }.keyboardShortcut("r", modifiers: .command)
            Divider()
            Button(i18n.t(.snippets)) { showSnippets?() }
            Button(i18n.t(.commandHistory)) { showCommandHistory?() }
            Divider()
            Button(i18n.t(.portForwarding)) { showPortForwarding?() }
            Button(i18n.t(.serialPort)) { showSerialPort?() }
        }
    }
}

private struct AIMenuCommands: Commands {
    let i18n: I18n
    @FocusedValue(\.menuToggleAI) private var toggleAI
    var body: some Commands {
        CommandMenu(i18n.t(.menuAI)) {
            Button(i18n.t(.aiAssistant)) { toggleAI?() }.keyboardShortcut("k", modifiers: .command)
        }
    }
}
#endif

// MARK: - Notification Names (legacy)

extension Notification.Name {
    static let menuNewTerminal = Notification.Name("bonk.menu.newTerminal")
    static let menuCloseTab = Notification.Name("bonk.menu.closeTab")
    static let menuFind = Notification.Name("bonk.menu.find")
    static let menuSplitHorizontal = Notification.Name("bonk.menu.splitHorizontal")
    static let menuSplitVertical = Notification.Name("bonk.menu.splitVertical")
    static let menuClosePane = Notification.Name("bonk.menu.closePane")
    static let menuToggleSFTP = Notification.Name("bonk.menu.toggleSFTP")
    static let menuToggleAI = Notification.Name("bonk.menu.toggleAI")
    static let menuChangeTheme = Notification.Name("bonk.menu.changeTheme")
    static let menuShowCommandHistory = Notification.Name("bonk.menu.showCommandHistory")
    static let menuConnect = Notification.Name("bonk.menu.connect")
    static let menuDisconnect = Notification.Name("bonk.menu.disconnect")
    static let menuReconnect = Notification.Name("bonk.menu.reconnect")
    static let menuShowSnippets = Notification.Name("bonk.menu.showSnippets")
    static let menuShowPortForwarding = Notification.Name("bonk.menu.showPortForwarding")
    static let menuShowSerialPort = Notification.Name("bonk.menu.showSerialPort")
}

#if os(macOS)
private struct SettingsContainerView: View {
    @Query private var allPreferences: [UserPreferences]
    @Environment(\.modelContext) private var modelContext
    private var preferences: UserPreferences { allPreferences.first ?? UserPreferences() }
    private func ensurePreferences() {
        if allPreferences.isEmpty { modelContext.insert(UserPreferences()) }
    }
    var body: some View {
        SettingsView(preferences: preferences).onAppear { ensurePreferences() }
    }
}
#endif
