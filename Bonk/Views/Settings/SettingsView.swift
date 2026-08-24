import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(I18n.self) var i18n
    @Bindable var preferences: UserPreferences
    @Bindable var quakeController: QuakeController
    @AppStorage("settings_selected_tab") private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(preferences: preferences)
                .tabItem { Label(i18n.t(.general), systemImage: "gearshape") }
                .tag("general")

            AppearanceSettingsView(preferences: preferences)
                .tabItem { Label(i18n.t(.appearance), systemImage: "paintbrush") }
                .tag("appearance")

            EditorSettingsView(preferences: preferences)
                .tabItem { Label(i18n.t(.terminal), systemImage: "terminal") }
                .tag("editor")

            KeyboardSettingsView(preferences: preferences)
                .tabItem { Label(i18n.t(.keyboard), systemImage: "keyboard") }
                .tag("keyboard")

            GroupSettingsView()
                .tabItem { Label(i18n.t(.groups), systemImage: "folder") }
                .tag("groups")

            QuakeSettingsView(quakeController: quakeController)
                .tabItem { Label(i18n.t(.quakeTerminal), systemImage: "arrow.down.to.line") }
                .tag("quake")

            TriggerSettingsView()
                .tabItem { Label("Triggers", systemImage: "bolt.trianglebadge.exclamationmark") }
                .tag("triggers")

            AISettingsView()
                .tabItem { Label(i18n.t(.ai), systemImage: "sparkles") }
                .tag("ai")
        }
        .frame(width: AppStyle.settingsWindowWidth, height: 500)
        .environment(\.locale, Locale(identifier: i18n.lang))
        .onAppear {
            updateWindowTitle()
        }
        .onChange(of: selectedTab) { _, _ in updateWindowTitle() }
        .onChange(of: i18n.lang) { _, _ in updateWindowTitle() }
    }

    private func updateWindowTitle() {
        #if os(macOS)
            DispatchQueue.main.async {
                NSApplication.shared.keyWindow?.title = i18n.t(LKey(rawValue: selectedTab) ?? .settings)
            }
        #endif
    }
}
