import SwiftData
import SwiftUI

/// Editor for saved serial port hosts (sidebar entries).
struct SerialPortEditSheet: View {
    @Environment(I18n.self) var i18n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostGroup.sortOrder) private var hostGroups: [HostGroup]

    let host: HostItem

    @State private var name = ""
    @State private var path = ""
    @State private var baudRate = 115_200
    @State private var group = ""

    var body: some View {
        Form {
            Section(i18n.t(.serialPort)) {
                TextField(i18n.t(.displayName), text: $name)
                TextField(i18n.t(.portPath), text: $path)
                    .autocorrectionDisabled()
                Picker(i18n.t(.baudRate), selection: $baudRate) {
                    ForEach(SerialPortConfig.defaultBaudRates, id: \.self) { rate in
                        Text("\(rate)").tag(rate)
                    }
                }
                GroupComboBoxView(group: $group)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(i18n.t(.editSerialPort))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(i18n.t(.cancel)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.save)) { save() }
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty
                            || path.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            name = host.name
            path = host.host
            baudRate = host.serialBaudRate ?? 115_200
            group = host.groupRef?.name ?? ""
        }
    }

    // MARK: - Actions

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        let trimmedGroup = group.trimmingCharacters(in: .whitespaces)

        host.name = trimmedName
        host.host = trimmedPath
        host.serialBaudRate = baudRate

        if let existing = hostGroups.first(where: { $0.name == trimmedGroup }) {
            host.groupRef = existing
        } else if !trimmedGroup.isEmpty {
            let newGroup = HostGroup(name: trimmedGroup)
            modelContext.insert(newGroup)
            host.groupRef = newGroup
        } else {
            host.groupRef = nil
        }

        try? modelContext.save()
        dismiss()
    }
}
