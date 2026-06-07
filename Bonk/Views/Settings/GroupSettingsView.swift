import SwiftData
import SwiftUI

// MARK: - Group Settings

struct GroupSettingsView: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostGroup.sortOrder) private var groups: [HostGroup]

    @State private var editingGroup: HostGroup?
    @State private var showAddSheet = false
    @State private var pendingDelete: HostGroup?

    var body: some View {
        VStack(spacing: 0) {
            if groups.isEmpty { emptyState } else { groupList }
            Divider()
            HStack {
                Spacer()
                Button { showAddSheet = true } label: { Label(i18n.t(.addGroup), systemImage: "plus") }
            }
            .padding(12)
        }
        .sheet(isPresented: $showAddSheet) { GroupEditSheet(group: nil, existingNames: groups.map(\.name)) }
        .sheet(item: $editingGroup) { GroupEditSheet(group: $0, existingNames: groups.map(\.name)) }
        .alert(i18n.t(.delete), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(i18n.t(.delete), role: .destructive) {
                if let target = pendingDelete { deleteGroup(target) }
            }
            Button(i18n.t(.cancel), role: .cancel) { pendingDelete = nil }
        } message: {
            if let target = pendingDelete {
                Text(i18n.tr(.deleteGroupConfirm, args: target.name))
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "folder.badge.plus").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text(i18n.t(.noGroups)).font(.headline).foregroundStyle(.secondary)
            Text(i18n.t(.noGroupsHint)).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Group List

    private var groupList: some View {
        List {
            ForEach(groups) { group in
                Button { editingGroup = group } label: {
                    HStack(spacing: 12) {
                        GroupIndicator(group: group)
                        Text(group.name).font(.body)
                        Spacer()
                        hostCountBadge(group.name)
                        Button { pendingDelete = group } label: {
                            Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func hostCountBadge(_ groupName: String) -> some View {
        let group = groups.first(where: { $0.name == groupName })
        let count = group?.hosts.count ?? 0
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(nsColor: .tertiaryLabelColor).opacity(0.15))
                .clipShape(Capsule())
        }
    }

    private func deleteGroup(_ group: HostGroup) {
        // Nullify relationships before deleting
        for host in group.hosts {
            host.groupRef = nil
        }
        modelContext.delete(group)
    }
}

// MARK: - Group Edit Sheet

struct GroupEditSheet: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let group: HostGroup?
    let existingNames: [String]

    @State private var name = ""
    @State private var selectedColor: String?
    @State private var customColor: Color = .blue
    @State private var selectedIcon: String?
    @State private var iconSearch = ""
    @State private var showIconPicker = false

    private var isEditing: Bool {
        group != nil
    }

    private var filteredIcons: [String] {
        if iconSearch.isEmpty { return Self.defaultIcons }
        return SFSymbols.all.filter { $0.localizedCaseInsensitiveContains(iconSearch) }
    }

    var body: some View {
        Form {
            Section(i18n.t(.groupName)) {
                TextField(i18n.t(.groupName), text: $name).autocorrectionDisabled()
            }
            Section(i18n.t(.groupColor)) { colorPicker }
            Section(i18n.t(.groupIcon)) { iconPicker }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 440)
        .navigationTitle(isEditing ? i18n.t(.editGroup) : i18n.t(.addGroup))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(i18n.t(.cancel)) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.save)) { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { loadExisting() }
    }

    // MARK: - Color Picker

    private var colorPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 8), count: 10), spacing: 8) {
            ForEach(HostGroup.presetColors, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex)).frame(width: 28, height: 28)
                    .overlay(Circle().stroke(selectedColor == hex ? Color.accentColor : .clear, lineWidth: 3))
                    .onTapGesture { selectedColor = selectedColor == hex ? nil : hex }
            }
            ColorPicker("", selection: $customColor, supportsOpacity: false)
                .labelsHidden().frame(width: 28, height: 28)
                .onChange(of: customColor) { _, newColor in
                    selectedColor = newColor.hexString
                }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Icon Picker

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let icon = selectedIcon, !icon.isEmpty {
                    Image(systemName: icon).font(.system(size: 16)).frame(width: 24)
                    Text(icon).font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24)
                    Text(i18n.t(.noIcon)).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button { showIconPicker.toggle() } label: {
                    Text(showIconPicker ? i18n.t(.done) : i18n.t(.edit)).font(.caption)
                }
            }

            if showIconPicker {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.caption)
                    TextField("SF Symbols", text: $iconSearch).textFieldStyle(.plain).font(.caption)
                }
                .padding(6).background(Color(nsColor: .controlBackgroundColor)).clipShape(.rect(cornerRadius: 6))

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 10), spacing: 6) {
                        iconCell(nil) // no icon option
                        ForEach(filteredIcons, id: \.self) { iconCell($0) }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private func iconCell(_ icon: String?) -> some View {
        Button {
            selectedIcon = icon
            if icon != nil { showIconPicker = false }
        } label: {
            Image(systemName: icon ?? "slash.circle")
                .font(.system(size: 16)).frame(width: 32, height: 32)
                .background(selectedIcon == icon ? Color.accentColor.opacity(0.15) : .clear)
                .clipShape(.rect(cornerRadius: 6))
                .foregroundStyle(icon == nil ? .tertiary : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func loadExisting() {
        guard let existing = group else { return }
        name = existing.name
        selectedColor = existing.colorHex
        selectedIcon = existing.icon
        if let hex = existing.colorHex {
            customColor = Color(hex: hex)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let existing = group {
            existing.name = trimmed
            existing.colorHex = selectedColor
            existing.icon = selectedIcon
        } else {
            let newGroup = HostGroup(
                name: trimmed,
                colorHex: selectedColor,
                icon: selectedIcon,
                sortOrder: existingNames.count
            )
            modelContext.insert(newGroup)
        }
        dismiss()
    }

    /// Default icons shown when search is empty.
    private static let defaultIcons = [
        "server.rack", "cloud", "shield", "globe", "terminal",
        "desktopcomputer", "laptopcomputer", "iphone", "network",
        "lock.shield", "key", "antenna.radiowaves.left.and.right",
        "externaldrive", "cpu", "memorychip", "bolt", "wifi",
        "house", "building.2", "cart", "hammer", "wrench",
        "star", "flag", "tag", "bookmark", "pin",
        "heart", "flame", "drop", "leaf", "sun.max",
        "moon", "sparkles", "command", "atom"
    ]
}
