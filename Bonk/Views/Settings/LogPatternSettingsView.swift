import SwiftUI
import SwiftData
import AppKit

// MARK: - Main

struct LogPatternSettingsView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LogProfile.createdAt) private var profiles: [LogProfile]
    @State private var selectedID: UUID?
    @State private var showAdd = false
    @State private var editingRow: LogPatternRow?
    @State private var showDeleteProfile = false
    @State private var showDeleteRow = false
    @State private var rowToDelete: LogPatternRow?
    @State private var editingName = false
    @State private var draftName = ""

    var selected: LogProfile? {
        profiles.first { $0.id == selectedID } ?? profiles.first { $0.isDefault } ?? profiles.first
    }

    var body: some View {
        HSplitView {
            List(profiles, id: \.id, selection: $selectedID) { profile in
                HStack(spacing: AppStyle.spacingS) {
                    Circle().fill(profile.isDefault ? Color.green : Color.blue).frame(width: 8, height: 8)
                    Text(profile.name).font(.system(size: AppStyle.fontBody)).lineLimit(1)
                    Spacer()
                    if profile.isDefault {
                        Text(i18n.t(.logDefaultBadge)).font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                    }
                }.tag(profile.id).padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 180, maxWidth: 220)

            if let profile = selected {
                VStack(spacing: 0) {
                    header(profile)
                    Divider()
                    previewSection(profile)
                    Divider()
                    rulesHeader
                    rulesList(profile)
                }
            } else {
                ContentUnavailableView(i18n.t(.logEmptyTitle), systemImage: "paintbrush", description: Text(i18n.t(.logEmptyDesc)))
            }
        }
        // Gap between the tab menu and the split content: without it the
        // vertical divider runs into the tab bar and reads as one cut.
        .padding(.top, AppStyle.spacingM)
        .sheet(isPresented: $showAdd) { PatternEditSheet(mode: .add, profile: selected) }
        .sheet(item: $editingRow) { row in PatternEditSheet(mode: .edit(row), profile: selected) }
        .onAppear {
            if selectedID == nil { selectedID = profiles.first { $0.isDefault }?.id ?? profiles.first?.id }
            LogProfileStore.shared.configure(container: modelContext.container)
        }
    }

    // MARK: - Subviews

    private func header(_ profile: LogProfile) -> some View {
        HStack(spacing: AppStyle.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                if editingName {
                    TextField(i18n.t(.logNamePlaceholder), text: $draftName, onCommit: {
                        profile.name = draftName; try? modelContext.save()
                        Task { @MainActor in LogProfileStore.shared.refreshSnapshot() }
                        editingName = false
                    }).font(.system(size: AppStyle.fontMedium, weight: .semibold)).frame(width: 180)
                        .onExitCommand { editingName = false }
                } else {
                    HStack(spacing: 6) {
                        Text(profile.name).font(.system(size: AppStyle.fontMedium, weight: .semibold))
                        Button { draftName = profile.name; editingName = true } label: { Image(systemName: "pencil").font(.system(size: 11)) }.buttonStyle(.plain).help(i18n.t(.logRename))
                    }
                }
                Text(i18n.tr(.logRulesCount, args: profile.patterns.count, profile.patterns.filter { $0.enabled }.count))
                    .font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(i18n.t(.logNewProfile)) {
                if let newProfile = LogProfileStore.shared.create(name: i18n.tr(.logNewProfileName, args: profiles.count + 1)) { selectedID = newProfile.id }
            }.controlSize(.small)
            if !profile.isDefault {
                Button(i18n.t(.delete), role: .destructive) { showDeleteProfile = true }.controlSize(.small).buttonStyle(.bordered)
            }
        }.padding(AppStyle.spacingM)
        .confirmationDialog(i18n.tr(.logDeleteProfileTitle, args: profile.name), isPresented: $showDeleteProfile, titleVisibility: .visible) {
            Button(i18n.t(.delete), role: .destructive) {
                modelContext.delete(profile); try? modelContext.save()
                selectedID = profiles.first { $0.id != profile.id }?.id
                Task { @MainActor in LogProfileStore.shared.refreshSnapshot() }
            }
            Button(i18n.t(.cancel), role: .cancel) {}
        } message: { Text(i18n.tr(.logDeleteProfileMsg, args: profile.patterns.count)) }
    }

    private func previewSection(_ profile: LogProfile) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.spacingS) {
            Label(i18n.t(.logLivePreview), systemImage: "eye").font(.system(size: AppStyle.fontSmall, weight: .medium)).foregroundStyle(.secondary)
            LogPreviewView(profile: profile)
                .padding(AppStyle.spacingS)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(AppStyle.cornerRadiusSmall)
                .overlay(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }.padding(AppStyle.spacingM)
    }

    private var rulesHeader: some View {
        HStack {
            Text(i18n.t(.logRules)).font(.system(size: AppStyle.fontSmall, weight: .semibold))
            Spacer()
            Button { showAdd = true } label: { Label(i18n.t(.logAddPattern), systemImage: "plus") }.controlSize(.small).buttonStyle(.borderedProminent)
        }.padding(.horizontal, AppStyle.spacingM).padding(.vertical, AppStyle.spacingS)
    }

    private func rulesList(_ profile: LogProfile) -> some View {
        List {
            ForEach(profile.patterns) { row in
                PatternRowView(row: row, onEdit: { editingRow = row }, onDelete: { rowToDelete = row; showDeleteRow = true })
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
        }.listStyle(.plain)
        .confirmationDialog(i18n.t(.logDeletePatternTitle), isPresented: $showDeleteRow, titleVisibility: .visible) {
            if let row = rowToDelete {
                Button(i18n.tr(.logDeletePatternButton, args: row.name), role: .destructive) {
                    modelContext.delete(row); try? modelContext.save()
                    Task { @MainActor in LogProfileStore.shared.refreshSnapshot() }
                }
                Button(i18n.t(.cancel), role: .cancel) {}
            }
        } message: { Text(i18n.t(.logDeletePatternMsg)) }
    }
}

// MARK: - Preview

struct LogPreviewView: View {
    let profile: LogProfile
    @State private var multi = "2026-08-27 10:00:00 INFO hello 192.168.1.1\n2026-08-27 10:00:00 ERROR failed 10.0.0.1\n{\"level\":\"error\",\"msg\":\"boom\"}\nlevel=warn msg=\"slow\"\nmy-alert-service Up 5 minutes\n2026/08/27 10:00:00 [error] 192.168.1.1"
    var body: some View {
        ProfileHighlightField(text: $multi, profile: profile)
            .frame(minHeight: 72, idealHeight: 84, maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
    }
}
