import SwiftUI
import SwiftData
import AppKit

// MARK: - Main

struct LogPatternSettingsView: View {
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
                        Text("默认").font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
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
                ContentUnavailableView("无配置", systemImage: "paintbrush", description: Text("新建一个日志着色配置"))
            }
        }
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
                    TextField("名称", text: $draftName, onCommit: {
                        profile.name = draftName; try? modelContext.save()
                        Task { @MainActor in LogProfileStore.shared.refreshSnapshot() }
                        editingName = false
                    }).font(.system(size: AppStyle.fontMedium, weight: .semibold)).frame(width: 180)
                        .onExitCommand { editingName = false }
                } else {
                    HStack(spacing: 6) {
                        Text(profile.name).font(.system(size: AppStyle.fontMedium, weight: .semibold))
                        Button { draftName = profile.name; editingName = true } label: { Image(systemName: "pencil").font(.system(size: 11)) }.buttonStyle(.plain).help("重命名")
                    }
                }
                Text("\(profile.patterns.count) 条规则 · \(profile.patterns.filter { $0.enabled }.count) 启用")
                    .font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("新建配置") {
                if let newProfile = LogProfileStore.shared.create(name: "配置 \(profiles.count + 1)") { selectedID = newProfile.id }
            }.controlSize(.small)
            if !profile.isDefault {
                Button("删除", role: .destructive) { showDeleteProfile = true }.controlSize(.small).buttonStyle(.bordered)
            }
        }.padding(AppStyle.spacingM)
        .confirmationDialog("删除配置 \(profile.name)？", isPresented: $showDeleteProfile, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                modelContext.delete(profile); try? modelContext.save()
                selectedID = profiles.first { $0.id != profile.id }?.id
                Task { @MainActor in LogProfileStore.shared.refreshSnapshot() }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("配置内 \(profile.patterns.count) 条规则将一并删除，不可恢复") }
    }

    private func previewSection(_ profile: LogProfile) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.spacingS) {
            Label("实时预览", systemImage: "eye").font(.system(size: AppStyle.fontSmall, weight: .medium)).foregroundStyle(.secondary)
            LogPreviewView(profile: profile)
                .padding(AppStyle.spacingS)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(AppStyle.cornerRadiusSmall)
                .overlay(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }.padding(AppStyle.spacingM)
    }

    private var rulesHeader: some View {
        HStack {
            Text("规则").font(.system(size: AppStyle.fontSmall, weight: .semibold))
            Spacer()
            Button { showAdd = true } label: { Label("添加正则", systemImage: "plus") }.controlSize(.small).buttonStyle(.borderedProminent)
        }.padding(.horizontal, AppStyle.spacingM).padding(.vertical, AppStyle.spacingS)
    }

    private func rulesList(_ profile: LogProfile) -> some View {
        List {
            ForEach(profile.patterns) { row in
                PatternRowView(row: row, onEdit: { editingRow = row }, onDelete: { rowToDelete = row; showDeleteRow = true })
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
        }.listStyle(.plain)
        .confirmationDialog("删除正则", isPresented: $showDeleteRow, titleVisibility: .visible) {
            if let row = rowToDelete {
                Button("删除 \(row.name)", role: .destructive) {
                    modelContext.delete(row); try? modelContext.save()
                    Task { @MainActor in LogProfileStore.shared.refreshSnapshot() }
                }
                Button("取消", role: .cancel) {}
            }
        } message: { Text("正则删除后不可恢复") }
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
