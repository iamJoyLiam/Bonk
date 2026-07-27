import SwiftUI

struct GeneralSettingsView: View {
    @Environment(I18n.self) var i18n
    @Bindable var preferences: UserPreferences

    @State private var selectedLanguage = "system"
    @State private var showKeyGenerator = false

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
                Toggle(i18n.t(.checkUpdates), isOn: $preferences.checkForUpdates)
            }

            Section(i18n.t(.hostInformation)) {
                Toggle(i18n.t(.hostAutoFillClear), isOn: $preferences.hostAutoFillClear)
            }

            Section("SFTP") {
                Toggle(i18n.t(.sftpOverwriteAlways), isOn: Binding(
                    get: { preferences.sftpOverwriteAlways ?? false },
                    set: { preferences.sftpOverwriteAlways = $0 }
                ))

                HStack {
                    Text(i18n.t(.sftpDefaultLocalPath))
                    Spacer()
                    Text(preferences.sftpDefaultLocalPath ?? "~/Downloads")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200)
                    Button(i18n.t(.browse)) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.begin { response in
                            if response == .OK, let url = panel.url {
                                preferences.sftpDefaultLocalPath = url.path(percentEncoded: false)
                            }
                        }
                    }
                }
            }

            Section(i18n.t(.sshKeys)) {
                Button {
                    showKeyGenerator = true
                } label: {
                    HStack {
                        Image(systemName: "key.fill")
                            .frame(width: 20)
                        Text(i18n.t(.generateSSHKey))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showKeyGenerator) {
            SSHKeyGeneratorView()
        }
        .onAppear {
            selectedLanguage = i18n.savedChoice
        }
    }
}
