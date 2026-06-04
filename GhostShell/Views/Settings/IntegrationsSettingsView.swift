//
//  IntegrationsSettingsView.swift
//  GhostShell
//

import SwiftUI

struct IntegrationsSettingsView: View {
    @EnvironmentObject var i18n: I18n

    var body: some View {
        Form {
            Section(i18n.t(.services)) {
                LabeledContent(i18n.t(.docker)) {
                    Text(i18n.t(.notDetected)).foregroundStyle(.secondary)
                }
                LabeledContent(i18n.t(.kubernetes)) {
                    Text(i18n.t(.notConfigured)).foregroundStyle(.secondary)
                }
            }

            Section(i18n.t(.plugins)) {
                LabeledContent(i18n.t(.installed)) {
                    Text("0").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
