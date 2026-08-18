import SwiftData
import SwiftUI

/// Save prompt shown after a serial connection succeeds: name + group.
struct SerialPortSaveSheet: View {
    @Environment(I18n.self) var i18n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostGroup.sortOrder) private var hostGroups: [HostGroup]

    let config: SerialPortConfig

    @State private var name = ""
    @State private var group = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section(i18n.t(.serialPort)) {
                TextField(i18n.t(.displayName), text: $name)
                GroupComboBoxView(group: $group)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(i18n.t(.saveSerialPort))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(i18n.t(.cancel)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.save)) { save() }
                    .disabled(trimmedName.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            name = defaultName
        }
    }

    // MARK: - Actions

    private func save() {
        let host = HostItem(
            name: trimmedName,
            host: config.path,
            port: 0,
            username: "serial"
        )
        host.isSerial = true
        host.serialBaudRate = config.baudRate

        let trimmedGroup = group.trimmingCharacters(in: .whitespaces)
        if let existing = hostGroups.first(where: { $0.name == trimmedGroup }) {
            host.groupRef = existing
        } else if !trimmedGroup.isEmpty {
            let newGroup = HostGroup(name: trimmedGroup)
            modelContext.insert(newGroup)
            host.groupRef = newGroup
        }

        modelContext.insert(host)
        try? modelContext.save()
        dismiss()
    }

    private var defaultName: String {
        if !config.name.isEmpty { return config.name }
        let lastComponent = URL(fileURLWithPath: config.path).lastPathComponent
        if lastComponent.hasPrefix("cu.") {
            return String(lastComponent.dropFirst(3))
        }
        return config.path
    }
}
