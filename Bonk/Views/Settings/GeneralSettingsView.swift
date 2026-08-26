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

            Section(i18n.t(.sftp)) {
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
                        .frame(maxWidth: AppStyle.size200)
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
                    Label(i18n.t(.generateSSHKey), systemImage: "key.fill")
                }
            }

            Section(i18n.t(.recording)) {
                Toggle(i18n.t(.autoRecordSessions), isOn: Binding(
                    get: { preferences.autoRecord ?? false },
                    set: { preferences.autoRecord = $0 }
                ))
                Text(i18n.t(.autoRecordDesc))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(i18n.t(.sshConfig)) {
                Toggle(i18n.t(.autoSyncSSHConfig), isOn: Binding(
                    get: { preferences.autoSyncSSHConfig ?? false },
                    set: { preferences.autoSyncSSHConfig = $0 }
                ))
                Text(i18n.t(.autoSyncSSHConfigDesc))
                    .font(.caption).foregroundStyle(.secondary)
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
