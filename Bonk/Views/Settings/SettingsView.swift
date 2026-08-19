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

            JumpHostView(isPresented: .constant(true))
                .tabItem { Label(i18n.t(.jumpHosts), systemImage: "arrow.triangle.swap") }
                .tag("jump_hosts")

            QuakeSettingsView(quakeController: quakeController)
                .tabItem { Label(i18n.t(.quakeTerminal), systemImage: "arrow.down.to.line") }
                .tag("quake")

            AISettingsView()
                .tabItem { Label(i18n.t(.ai), systemImage: "sparkles") }
                .tag("ai")
        }
        .frame(width: 720, height: 500)
        .environment(\.locale, Locale(identifier: i18n.lang))
        .onAppear {
            // Account settings tab was removed — drop any stale selection.
            if selectedTab == "account" { selectedTab = "general" }
            updateWindowTitle()
        }
        .onChange(of: selectedTab) { _, _ in updateWindowTitle() }
        .onChange(of: i18n.lang) { _, _ in updateWindowTitle() }
    }

    private func updateWindowTitle() {
        #if os(macOS)
            DispatchQueue.main.async {
                // Account settings tab was removed — fall back to General.
                let tag = selectedTab == "account" ? "general" : selectedTab
                NSApplication.shared.keyWindow?.title = i18n.t(LKey(rawValue: tag) ?? .settings)
            }
        #endif
    }
}
