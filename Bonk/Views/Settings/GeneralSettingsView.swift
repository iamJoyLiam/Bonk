import SwiftUI

struct GeneralSettingsView: View {
  @EnvironmentObject var i18n: I18n
  @Bindable var preferences: UserPreferences

  @State private var selectedLanguage = "system"

  var body: some View {
    Form {
      Picker(i18n.t(.language) + ":", selection: $selectedLanguage) {
        Text(i18n.t(.system)).tag("system")
        ForEach(i18n.availableLanguages, id: \.self) { code in
          Text(i18n.displayName(for: code)).tag(code)
        }
      }
      .onChange(of: selectedLanguage) { _, newValue in
        i18n.setLanguage(newValue)
      }

      Section(i18n.t(.launchBehavior)) {
        Toggle(i18n.t(.restoreSessions), isOn: $preferences.restoreSessions)
        Toggle(i18n.t(.checkUpdates), isOn: $preferences.checkForUpdates)
      }

      Section(i18n.t(.hostInformation)) {
        Toggle(i18n.t(.hostAutoFillClear), isOn: $preferences.hostAutoFillClear)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .onAppear {
      selectedLanguage = i18n.savedChoice
    }
  }
}
