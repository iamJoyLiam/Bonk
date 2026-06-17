//
//  GroupComboBoxView.swift
//  Bonk
//
//  Group selection combo box for AddHostSheet.
//

import SwiftData
import SwiftUI

/// Group selection combo box with dropdown
struct GroupComboBoxView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostGroup.sortOrder) private var hostGroups: [HostGroup]

    @Binding var group: String
    @State private var showDropdown = false

    private var groupExists: Bool {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return hostGroups.contains {
            $0.name.lowercased() == trimmed.lowercased()
        }
    }

    private var selectedGroup: HostGroup? {
        hostGroups.first(where: { $0.name == group })
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(i18n.t(.groupOptional), text: $group)
                .autocorrectionDisabled()
                .onSubmit { commitGroup() }

            if let selected = selectedGroup, !group.isEmpty {
                GroupIndicator(group: selected)
            }

            if !group.isEmpty {
                Button { group = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Button { showDropdown.toggle() } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(
                isPresented: $showDropdown,
                arrowEdge: .bottom
            ) {
                groupDropdown.fixedSize()
            }
        }
    }

    // MARK: - Dropdown

    private var groupDropdown: some View {
        let input = group.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 0) {
            if hostGroups.isEmpty, input.isEmpty {
                Text(i18n.t(.noGroups))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(hostGroups) { hostGroup in
                            groupRow(hostGroup)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            if !input.isEmpty, !groupExists {
                Divider()
                Button {
                    commitGroup()
                    showDropdown = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.accentColor)
                        Text(input)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func groupRow(_ hostGroup: HostGroup) -> some View {
        Button {
            group = hostGroup.name
            showDropdown = false
        } label: {
            HStack(spacing: 6) {
                GroupIndicator(group: hostGroup)
                Text(hostGroup.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if hostGroup.name == group {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func commitGroup() {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !groupExists else { return }
        modelContext.insert(HostGroup(name: trimmed))
    }
}

// MARK: - Shared Indicator

/// Small color dot + icon, used in combo box, dropdown, and sidebar.
struct GroupIndicator: View {
    let group: HostGroup

    var body: some View {
        HStack(spacing: 4) {
            if let color = group.resolvedColor {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            if let icon = group.icon, !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
