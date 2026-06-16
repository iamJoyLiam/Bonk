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
            FileMenuCommands()

            // MARK: - Edit Menu
            EditMenuCommands()

            // MARK: - View Menu
            ViewMenuCommands()

            // MARK: - Connection Menu
            ConnectionMenuCommands()

            // MARK: - AI Menu
            AIMenuCommands()
        }

        #if os(macOS)
            Settings {
                SettingsContainerView()
                    .environment(i18n)
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

// MARK: - Menu Commands (FocusedValue — synchronous, zero NotificationCenter overhead)

#if os(macOS)
    struct FileMenuCommands: Commands {
        @FocusedValue(\.menuNewTerminal) private var newTerminal
        @FocusedValue(\.menuCloseTab) private var closeTab

        var body: some Commands {
            CommandGroup(after: .newItem) {
                Button("New Terminal") { newTerminal?() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { closeTab?() }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
    }

    struct EditMenuCommands: Commands {
        @FocusedValue(\.menuFind) private var find

        var body: some Commands {
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find") { find?() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }

    struct ViewMenuCommands: Commands {
        @FocusedValue(\.menuSplitHorizontal) private var splitHorizontal
        @FocusedValue(\.menuSplitVertical) private var splitVertical
        @FocusedValue(\.menuClosePane) private var closePane
        @FocusedValue(\.menuToggleSFTP) private var toggleSFTP
        @FocusedValue(\.menuChangeTheme) private var changeTheme

        var body: some Commands {
            CommandMenu("View") {
                Button("Split Horizontal") { splitHorizontal?() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Vertical") { splitVertical?() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close Pane") { closePane?() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("SFTP Browser") { toggleSFTP?() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Menu("Theme") {
                    Button("System") { changeTheme?("system") }
                    ForEach(ThemeRegistry.all, id: \.id) { theme in
                        Button(theme.name) { changeTheme?(theme.id) }
                    }
                }
            }
        }
    }

    struct ConnectionMenuCommands: Commands {
        @FocusedValue(\.menuConnect) private var connect
        @FocusedValue(\.menuDisconnect) private var disconnect
        @FocusedValue(\.menuReconnect) private var reconnect
        @FocusedValue(\.menuShowSnippets) private var showSnippets
        @FocusedValue(\.menuShowCommandHistory) private var showCommandHistory
        @FocusedValue(\.menuShowPortForwarding) private var showPortForwarding
        @FocusedValue(\.menuShowSerialPort) private var showSerialPort

        var body: some Commands {
            CommandMenu("Connection") {
                Button("Connect") { connect?() }
                Button("Disconnect") { disconnect?() }
                Button("Reconnect") { reconnect?() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Snippets") { showSnippets?() }
                Button("Command History") { showCommandHistory?() }
                Divider()
                Button("Port Forwarding") { showPortForwarding?() }
                Button("Serial Port") { showSerialPort?() }
            }
        }
    }

    struct AIMenuCommands: Commands {
        @FocusedValue(\.menuToggleAI) private var toggleAI

        var body: some Commands {
            CommandMenu("AI") {
                Button("AI Assistant") { toggleAI?() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
#endif


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
