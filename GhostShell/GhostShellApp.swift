import SwiftData
import SwiftUI
import AppKit
import os.log

@main
struct GhostShellApp: App {
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
    ])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

    do {
      return try ModelContainer(for: schema, configurations: [config])
    } catch {
      // Schema migration failed — delete old store and retry
      Log.general.warning(" Migration failed, recreating store: \(error)")
      let storeURL = config.url
      try? FileManager.default.removeItem(at: storeURL)
      try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
      try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
      do {
        return try ModelContainer(for: schema, configurations: [config])
      } catch {
        fatalError("Could not create ModelContainer even after reset: \(error)")
      }
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
      // Localized About + Check for Updates
      CommandGroup(replacing: .appInfo) {
        Button {
          NSApp.orderFrontStandardAboutPanel(nil)
        } label: {
          Label(i18n.t(.about) + " GhostShell", systemImage: "info.circle")
        }
        Divider()
        Button {
          updater.checkForUpdates()
        } label: {
          Label(i18n.t(.checkUpdates), systemImage: "arrow.triangle.2.circlepath")
        }
        .keyboardShortcut("u", modifiers: [.command, .option])
      }

      // AI menu
      CommandMenu("AI") {
        Button(i18n.t(.aiAssistant)) {
          NotificationCenter.default.post(name: .toggleAIChat, object: nil)
        }
        .keyboardShortcut("k", modifiers: .command)
      }
    }

    #if os(macOS)
      Settings {
        SettingsContainerView()
          .environmentObject(i18n)
      }
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
