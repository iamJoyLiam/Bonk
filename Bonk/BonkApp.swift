import AppKit
import os.log
import SwiftData
import SwiftUI

@main
struct BonkApp: App {
    @State private var i18n = I18n()
    @State private var updater = UpdaterManager()
    @State private var shortcutManager = ShortcutManager.shared

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
            Snippet.self, PortForward.self, JumpHost.self,
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
            FileMenuCommands(i18n: i18n, shortcutManager: shortcutManager)
            EditMenuCommands(i18n: i18n, shortcutManager: shortcutManager)
            ViewMenuCommands(i18n: i18n, shortcutManager: shortcutManager)
            ConnectionMenuCommands(i18n: i18n, shortcutManager: shortcutManager)
            AIMenuCommands(i18n: i18n, shortcutManager: shortcutManager)
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
        let shortcutManager: ShortcutManager
        @FocusedValue(\.menuNewTerminal) private var newTerminal
        @FocusedValue(\.menuCloseTab) private var closeTab
        var body: some Commands {
            let newTerminalShortcut = shortcutManager.shortcut(for: .newTerminal)
            let closeTabShortcut = shortcutManager.shortcut(for: .closeTab)
            CommandGroup(after: .newItem) {
                Button(i18n.t(.newTerminal)) { newTerminal?() }
                    .keyboardShortcut(newTerminalShortcut.key, modifiers: newTerminalShortcut.modifiers)
                Button(i18n.t(.closeTab)) { closeTab?() }
                    .keyboardShortcut(closeTabShortcut.key, modifiers: closeTabShortcut.modifiers)
            }
        }
    }

    private struct EditMenuCommands: Commands {
        let i18n: I18n
        let shortcutManager: ShortcutManager
        @FocusedValue(\.menuFind) private var find
        var body: some Commands {
            let findShortcut = shortcutManager.shortcut(for: .find)
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(i18n.t(.find)) { find?() }
                    .keyboardShortcut(findShortcut.key, modifiers: findShortcut.modifiers)
            }
        }
    }

    private struct ViewMenuCommands: Commands {
        let i18n: I18n
        let shortcutManager: ShortcutManager
        @FocusedValue(\.menuSplitHorizontal) private var splitHorizontal
        @FocusedValue(\.menuSplitVertical) private var splitVertical
        @FocusedValue(\.menuClosePane) private var closePane
        @FocusedValue(\.menuToggleSFTP) private var toggleSFTP
        @FocusedValue(\.menuChangeTheme) private var changeTheme
        var body: some Commands {
            let splitHorizontalShortcut = shortcutManager.shortcut(for: .splitHorizontal)
            let splitVerticalShortcut = shortcutManager.shortcut(for: .splitVertical)
            let closePaneShortcut = shortcutManager.shortcut(for: .closePane)
            let sftpBrowserShortcut = shortcutManager.shortcut(for: .sftpBrowser)
            CommandMenu(i18n.t(.menuView)) {
                Button(i18n.t(.splitHorizontal)) { splitHorizontal?() }
                    .keyboardShortcut(splitHorizontalShortcut.key, modifiers: splitHorizontalShortcut.modifiers)
                Button(i18n.t(.splitVertical)) { splitVertical?() }
                    .keyboardShortcut(splitVerticalShortcut.key, modifiers: splitVerticalShortcut.modifiers)
                Button(i18n.t(.closePane)) { closePane?() }
                    .keyboardShortcut(closePaneShortcut.key, modifiers: closePaneShortcut.modifiers)
                Divider()
                Button(i18n.t(.sftpBrowser)) { toggleSFTP?() }
                    .keyboardShortcut(sftpBrowserShortcut.key, modifiers: sftpBrowserShortcut.modifiers)
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
        let shortcutManager: ShortcutManager
        @FocusedValue(\.menuConnect) private var connect
        @FocusedValue(\.menuDisconnect) private var disconnect
        @FocusedValue(\.menuReconnect) private var reconnect
        @FocusedValue(\.menuShowSnippets) private var showSnippets
        @FocusedValue(\.menuShowCommandHistory) private var showCommandHistory
        @FocusedValue(\.menuShowPortForwarding) private var showPortForwarding
        @FocusedValue(\.menuShowSerialPort) private var showSerialPort
        var body: some Commands {
            let reconnectShortcut = shortcutManager.shortcut(for: .reconnect)
            CommandMenu(i18n.t(.menuConnection)) {
                Button(i18n.t(.connect)) { connect?() }
                Button(i18n.t(.disconnect)) { disconnect?() }
                Button(i18n.t(.reconnect)) { reconnect?() }
                    .keyboardShortcut(reconnectShortcut.key, modifiers: reconnectShortcut.modifiers)
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
        let shortcutManager: ShortcutManager
        @FocusedValue(\.menuToggleAI) private var toggleAI
        @FocusedValue(\.menuToggleAITerminal) private var toggleAITerminal
        var body: some Commands {
            let aiAssistantShortcut = shortcutManager.shortcut(for: .aiAssistant)
            let aiChatSidebarShortcut = shortcutManager.shortcut(for: .aiChatSidebar)
            CommandMenu(i18n.t(.menuAI)) {
                Button(i18n.t(.aiAssistant)) { toggleAITerminal?() }
                    .keyboardShortcut(aiAssistantShortcut.key, modifiers: aiAssistantShortcut.modifiers)
                Button(i18n.t(.aiChatSidebar)) { toggleAI?() }
                    .keyboardShortcut(aiChatSidebarShortcut.key, modifiers: aiChatSidebarShortcut.modifiers)
            }
        }
    }
#endif

#if os(macOS)
    private struct SettingsContainerView: View {
        @Query private var allPreferences: [UserPreferences]
        @Environment(\.modelContext) private var modelContext
        private var preferences: UserPreferences {
            allPreferences.first ?? UserPreferences()
        }

        private func ensurePreferences() {
            if allPreferences.isEmpty { modelContext.insert(UserPreferences()) }
        }

        var body: some View {
            SettingsView(preferences: preferences).onAppear { ensurePreferences() }
        }
    }
#endif
