import AppKit
import os.log
import SwiftData
import SwiftUI

@main
struct BonkApp: App {
    @StateObject private var i18n = I18n()
    @StateObject private var updater = UpdaterManager()

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
            HostItem.self,
            UserPreferences.self,
            Credential.self,
            HostGroup.self,
            AIConversationRecord.self,
            AIMessageRecord.self,
            AIProviderRecord.self,
            Snippet.self,
            SavedSession.self,
            PortForward.self,
            JumpHost.self,
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
                .environmentObject(i18n)
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
            // MARK: - App Info
            CommandGroup(replacing: .appInfo) {
                Button {
                    NSApp.orderFrontStandardAboutPanel(nil)
                } label: {
                    Label(i18n.t(.about) + " Bonk", systemImage: "info.circle")
                }
                Divider()
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label(i18n.t(.checkUpdates), systemImage: "arrow.triangle.2.circlepath")
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
            }

            // MARK: - File Menu
            CommandGroup(after: .newItem) {
                Button(i18n.t(.newTerminal)) {
                    NotificationCenter.default.post(name: .menuNewTerminal, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button(i18n.t(.closeTab)) {
                    NotificationCenter.default.post(name: .menuCloseTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            // MARK: - Edit Menu
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(i18n.t(.find)) {
                    NotificationCenter.default.post(name: .menuFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            // MARK: - View Menu
            CommandMenu(i18n.t(.menuView)) {
                Button(i18n.t(.splitHorizontal)) {
                    NotificationCenter.default.post(name: .menuSplitHorizontal, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button(i18n.t(.splitVertical)) {
                    NotificationCenter.default.post(name: .menuSplitVertical, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(i18n.t(.closePane)) {
                    NotificationCenter.default.post(name: .menuClosePane, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Divider()

                Button(i18n.t(.sftpBrowser)) {
                    NotificationCenter.default.post(name: .menuToggleSFTP, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button(i18n.t(.aiAssistant)) {
                    NotificationCenter.default.post(name: .menuToggleAI, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Divider()

                Menu(i18n.t(.theme)) {
                    Button(i18n.t(.system)) {
                        NotificationCenter.default.post(name: .menuChangeTheme, object: "system")
                    }
                    ForEach(ThemeRegistry.all, id: \.id) { theme in
                        Button(theme.name) {
                            NotificationCenter.default.post(name: .menuChangeTheme, object: theme.id)
                        }
                    }
                }

                Divider()

                Button(i18n.t(.commandHistory)) {
                    NotificationCenter.default.post(name: .menuShowCommandHistory, object: nil)
                }
            }

            // MARK: - Connection Menu
            CommandMenu(i18n.t(.menuConnection)) {
                Button(i18n.t(.connect)) {
                    NotificationCenter.default.post(name: .menuConnect, object: nil)
                }

                Button(i18n.t(.disconnect)) {
                    NotificationCenter.default.post(name: .menuDisconnect, object: nil)
                }

                Button(i18n.t(.reconnect)) {
                    NotificationCenter.default.post(name: .menuReconnect, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button(i18n.t(.snippets)) {
                    NotificationCenter.default.post(name: .menuShowSnippets, object: nil)
                }

                Divider()

                Button(i18n.t(.portForwarding)) {
                    NotificationCenter.default.post(name: .menuShowPortForwarding, object: nil)
                }

                Button(i18n.t(.serialPort)) {
                    NotificationCenter.default.post(name: .menuShowSerialPort, object: nil)
                }
            }

            // MARK: - AI Menu
            CommandMenu(i18n.t(.menuAI)) {
                Button(i18n.t(.aiAssistant)) {
                    NotificationCenter.default.post(name: .menuToggleAI, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        #if os(macOS)
            Settings {
                SettingsContainerView()
                    .environmentObject(i18n)
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

// MARK: - Menu Notification Names

extension Notification.Name {
    // File
    static let menuNewTerminal = Notification.Name("bonk.menu.newTerminal")
    static let menuCloseTab = Notification.Name("bonk.menu.closeTab")

    // Edit
    static let menuFind = Notification.Name("bonk.menu.find")

    // View
    static let menuSplitHorizontal = Notification.Name("bonk.menu.splitHorizontal")
    static let menuSplitVertical = Notification.Name("bonk.menu.splitVertical")
    static let menuClosePane = Notification.Name("bonk.menu.closePane")
    static let menuToggleSFTP = Notification.Name("bonk.menu.toggleSFTP")
    static let menuToggleAI = Notification.Name("bonk.menu.toggleAI")
    static let menuChangeTheme = Notification.Name("bonk.menu.changeTheme")
    static let menuShowCommandHistory = Notification.Name("bonk.menu.showCommandHistory")

    // Connection
    static let menuConnect = Notification.Name("bonk.menu.connect")
    static let menuDisconnect = Notification.Name("bonk.menu.disconnect")
    static let menuReconnect = Notification.Name("bonk.menu.reconnect")
    static let menuShowSnippets = Notification.Name("bonk.menu.showSnippets")
    static let menuShowPortForwarding = Notification.Name("bonk.menu.showPortForwarding")
    static let menuShowSerialPort = Notification.Name("bonk.menu.showSerialPort")

}

#if os(macOS)
    /// Settings scene container that accesses SwiftData.
    private struct SettingsContainerView: View {
        @Query private var allPreferences: [UserPreferences]
        @Environment(\.modelContext) private var modelContext

        private var preferences: UserPreferences {
            allPreferences.first ?? UserPreferences()
        }

        private func ensurePreferences() {
            if allPreferences.isEmpty {
                let new = UserPreferences()
                modelContext.insert(new)
            }
        }

        var body: some View {
            SettingsView(preferences: preferences)
                .onAppear { ensurePreferences() }
        }
    }
#endif
