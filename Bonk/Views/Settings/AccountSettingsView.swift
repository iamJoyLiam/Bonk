import SwiftUI

struct AccountSettingsView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @State private var syncService = ICloudSyncService.shared

    var body: some View {
        Form {
            Section(i18n.t(.license)) {
                LabeledContent(i18n.t(.licenseKey)) {
                    HStack(spacing: 6) {
                        Text(i18n.t(.notActivated)).foregroundStyle(.secondary)
                        Button(i18n.t(.activate)) {}.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                LabeledContent(i18n.t(.status)) {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text(i18n.t(.inactive)).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(i18n.t(.plan)) {
                    Text(i18n.t(.free)).foregroundStyle(.secondary)
                }
            }

            Section(i18n.t(.sync)) {
                Toggle(i18n.t(.icloudSync), isOn: $syncService.isEnabled)

                if syncService.isEnabled {
                    Toggle(i18n.t(.syncHosts), isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "sync_hosts") },
                        set: { UserDefaults.standard.set($0, forKey: "sync_hosts") }
                    ))
                    Toggle(i18n.t(.syncPrefs), isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "sync_prefs") },
                        set: { UserDefaults.standard.set($0, forKey: "sync_prefs") }
                    ))

                    LabeledContent(i18n.t(.lastSynced)) {
                        if let lastSynced = syncService.lastSynced {
                            Text(lastSynced, style: .relative)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(i18n.t(.never)).foregroundStyle(.secondary)
                        }
                    }

                    Button(i18n.t(.syncNow)) {
                        syncService.syncToCloud()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Show hint for local builds
                Label(
                    "iCloud sync requires Apple Developer account and App Store distribution.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let error = syncService.syncError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            syncService.setModelContext(modelContext)
        }
    }
}
