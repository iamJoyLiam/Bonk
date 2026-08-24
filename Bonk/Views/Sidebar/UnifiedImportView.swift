//
//  UnifiedImportView.swift
//  Bonk – single “Import” that auto-detects SSH config + Tabby
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct UnifiedImportView: View {
    let modelContext: ModelContext
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss

    @State private var sshEntries: [SSHConfigEntry] = []
    @State private var tabbyHosts: [HostItem] = []
    @State private var selectedSSH: Set<UUID> = []
    @State private var selectedTabby: Set<UUID> = []
    @State private var existingNames: Set<String> = []
    @State private var tabbyError: String?
    @State private var isImporting = false
    @State private var showResult = false
    @State private var resultCreated = 0
    @State private var resultSkipped = 0
    @State private var tabbySourceURL: URL?

    var totalCount: Int { sshEntries.count + tabbyHosts.count }
    var selectedCount: Int { selectedSSH.count + selectedTabby.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if totalCount == 0 {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { load() }
        .alert(i18n.t(.importResult), isPresented: $showResult) {
            Button(i18n.t(.ok)) { dismiss() }
        } message: {
            Text(i18n.tr(.importSuccessMessage, args: resultCreated, resultSkipped, 0))
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "square.and.arrow.down").font(.title2).foregroundStyle(.blue)
                Text(i18n.t(.importSessions)).font(.headline)
                Spacer()
                Text("\(selectedCount)/\(totalCount)").font(.caption).foregroundStyle(.secondary)
            }
            Text(i18n.t(.importUnifiedDescription))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let url = tabbySourceURL {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text("Tabby: \(url.lastPathComponent) — \(url.path)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(i18n.t(.noSSHConfigEntries)).font(.headline)
            Text(i18n.t(.noSSHConfigEntriesDescription)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let err = tabbyError {
                Text(err).font(.caption2).foregroundStyle(.orange)
            }
            Button(i18n.t(.chooseFile)) { promptForTabbyFile() }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !sshEntries.isEmpty {
                    Section {
                        ForEach(sshEntries) { e in
                            sshRow(e)
                            if e.id != sshEntries.last?.id { Divider().padding(.leading, 44) }
                        }
                    } header: {
                        sectionHeader(title: "\(i18n.t(.importSSHConfig)) — \(sshEntries.count) \(i18n.t(.hostsFound))")
                    }
                }
                if !tabbyHosts.isEmpty {
                    Section {
                        ForEach(tabbyHosts, id: \.id) { h in
                            tabbyRow(h)
                            if h.id != tabbyHosts.last?.id { Divider().padding(.leading, 44) }
                        }
                    } header: {
                        sectionHeader(title: "\(i18n.t(.importTabby)) — \(tabbyHosts.count) \(i18n.t(.hostsFound))")
                    }
                }
            }.padding(.vertical, 8)
        }
    }

    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    // Cache non-duplicate IDs to avoid O(n*m) on every Select All tap
    private var nonDuplicateSSHIDs: Set<UUID> { Set(sshEntries.filter { !existingNames.contains($0.alias) }.map(\.id)) }
    private var nonDuplicateTabbyIDs: Set<UUID> { Set(tabbyHosts.filter { !existingNames.contains($0.name) }.map(\.id)) }

    private func sshRow(_ entry: SSHConfigEntry) -> some View {
        ImportRowView(
            title: entry.alias,
            hostname: entry.hostname ?? entry.alias,
            port: entry.port.map { Int($0) } ?? SSHConstants.defaultPort,
            username: entry.user ?? "",
            isSelected: selectedSSH.contains(entry.id),
            isDuplicate: existingNames.contains(entry.alias),
            badgeTitle: "SSH",
            badgeColor: .secondary,
            onToggle: { toggleSSH(entry.id) }
        )
    }

    private func tabbyRow(_ hostItem: HostItem) -> some View {
        ImportRowView(
            title: hostItem.name,
            hostname: hostItem.host,
            port: hostItem.port,
            username: hostItem.username,
            isSelected: selectedTabby.contains(hostItem.id),
            isDuplicate: existingNames.contains(hostItem.name),
            badgeTitle: "Tabby",
            badgeColor: .orange,
            onToggle: { toggleTabby(hostItem.id) }
        )
    }

    private var footer: some View {
        HStack {
            Button(selectedCount == totalCount ? i18n.t(.deselectAll) : i18n.t(.selectAll)) {
                if selectedCount == totalCount { selectedSSH.removeAll(); selectedTabby.removeAll() }
                else {
                    selectedSSH = nonDuplicateSSHIDs
                    selectedTabby = nonDuplicateTabbyIDs
                }
            }.disabled(totalCount == 0)
            Spacer()
            Button(i18n.t(.chooseFile)) { promptForTabbyFile() }
            Button(i18n.t(.cancel)) { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                performImport()
            } label: {
                if isImporting { ProgressView().controlSize(.small) } else { Text(i18n.t(.importSessions)) }
            }.disabled(selectedCount == 0 || isImporting).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }.padding()
    }

    private func toggleSSH(_ id: UUID) { if selectedSSH.contains(id) { selectedSSH.remove(id) } else { selectedSSH.insert(id) } }
    private func toggleTabby(_ id: UUID) { if selectedTabby.contains(id) { selectedTabby.remove(id) } else { selectedTabby.insert(id) } }

    private func load() {
        if let all = try? modelContext.fetch(FetchDescriptor<HostItem>()) { existingNames = Set(all.map(\.name)) }
        // SSH config
        do { sshEntries = try SSHConfigParser.parse() } catch { sshEntries = [] }
        selectedSSH = Set(sshEntries.filter { !existingNames.contains($0.alias) }.map(\.id))
        // Tabby auto-detect
        let importer = TabbyImporter()
        for url in importer.discoverDefaultLocations() where FileManager.default.fileExists(atPath: url.path) {
            do {
                tabbyHosts = try importer.importSessions(from: url)
                tabbySourceURL = url
                selectedTabby = Set(tabbyHosts.filter { !existingNames.contains($0.name) }.map(\.id))
                tabbyError = nil
                return
            } catch { tabbyError = error.localizedDescription }
        }
        // No auto file — leave empty, user can pick via Choose File
    }

    private func promptForTabbyFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json, UTType.yaml, UTType(filenameExtension: "yml") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let items = try TabbyImporter().importSessions(from: url)
                tabbyHosts = items
                selectedTabby = Set(items.filter { !existingNames.contains($0.name) }.map(\.id))
                tabbySourceURL = url
                tabbyError = nil
            } catch { tabbyError = error.localizedDescription }
        }
    }

    private func performImport() {
        isImporting = true
        var created = 0, skipped = 0
        // SSH
        for e in sshEntries where selectedSSH.contains(e.id) {
            if existingNames.contains(e.alias) { skipped += 1; continue }
            let host = e.hostname ?? e.alias
            let port = Int(e.port ?? 22)
            let user = e.user ?? NSUserName()
            let item = HostItem(name: e.alias, host: host, port: port, username: user, authType: .privateKey, privateKeyPEM: loadKey(e.identityFile))
            modelContext.insert(item)
            existingNames.insert(e.alias); created += 1
        }
        // Tabby
        for h in tabbyHosts where selectedTabby.contains(h.id) {
            if existingNames.contains(h.name) { skipped += 1; continue }
            modelContext.insert(h)
            existingNames.insert(h.name); created += 1
        }
        try? modelContext.save()
        resultCreated = created; resultSkipped = skipped
        isImporting = false; showResult = true
    }

    private func loadKey(_ path: String?) -> String? {
        guard let path else { return nil }
        let p = NSString(string: path).expandingTildeInPath
        guard let d = FileManager.default.contents(atPath: p), let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }
}
