//
//  UnifiedImportView.swift
//  Bonk – single “Import” that auto-detects SSH config + Tabby / iTerm2 / Electerm / WindTerm / CSV
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct UnifiedImportView: View {
    let modelContext: ModelContext
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss

    @State private var sshEntries: [SSHConfigEntry] = []
    @State private var externalHosts: [(HostItem, String)] = [] // (host, sourceName)
    @State private var selectedSSH: Set<UUID> = []
    @State private var selectedExternal: Set<UUID> = []
    @State private var existingNames: Set<String> = []
    @State private var importError: String?
    @State private var isImporting = false
    @State private var showResult = false
    @State private var resultCreated = 0
    @State private var resultSkipped = 0

    private var totalCount: Int { sshEntries.count + externalHosts.count }
    private var selectedCount: Int { selectedSSH.count + selectedExternal.count }

    // All importers for auto-detect (order: specific → generic)
    private var importers: [any SessionImporter] {
        [TabbyImporter(), ITerm2Importer(), ElectermImporter(), WindTermImporter(), GenericCSVImporter()]
    }

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
        }.padding()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(i18n.t(.noSSHConfigEntries)).font(.headline)
            Text(i18n.t(.noSSHConfigEntriesDescription)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let err = importError {
                Text(err).font(.caption2).foregroundStyle(.orange)
            }
            Button(i18n.t(.chooseFile)) { promptForFile() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Text("自动识别 SSH Config / Tabby / iTerm2 / Electerm / WindTerm / CSV")
                .font(.caption2).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // Single merged list — auto-detected SSH config + external importers, no section split
    private struct MergedEntry: Identifiable {
        let id: UUID
        let title: String
        let hostname: String
        let port: Int
        let username: String
        let source: String
        let isSSH: Bool
        let isDuplicate: Bool
    }

    private var mergedEntries: [MergedEntry] {
        var list: [MergedEntry] = []
        for entry in sshEntries {
            list.append(MergedEntry(
                id: entry.id,
                title: entry.alias,
                hostname: entry.hostname ?? entry.alias,
                port: entry.port.map { Int($0) } ?? SSHConstants.defaultPort,
                username: entry.user ?? "",
                source: "SSH",
                isSSH: true,
                isDuplicate: existingNames.contains(entry.alias)
            ))
        }
        for (hostItem, source) in externalHosts {
            list.append(MergedEntry(
                id: hostItem.id,
                title: hostItem.name,
                hostname: hostItem.host,
                port: hostItem.port,
                username: hostItem.username,
                source: source,
                isSSH: false,
                isDuplicate: existingNames.contains(hostItem.name)
            ))
        }
        return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(mergedEntries) { entry in
                    ImportRowView(
                        title: entry.title,
                        hostname: entry.hostname,
                        port: entry.port,
                        username: entry.username,
                        isSelected: entry.isSSH ? selectedSSH.contains(entry.id) : selectedExternal.contains(entry.id),
                        isDuplicate: entry.isDuplicate,
                        badgeTitle: entry.source,
                        badgeColor: badgeColor(for: entry.source),
                        onToggle: {
                            if entry.isSSH { toggleSSH(entry.id) } else { toggleExternal(entry.id) }
                        }
                    )
                    if entry.id != mergedEntries.last?.id { Divider().padding(.leading, 44) }
                }
            }.padding(.vertical, 8)
        }
    }

    private func badgeColor(for source: String) -> Color {
        switch source {
        case "SSH": return .secondary
        case "Tabby": return .orange
        case "iTerm2": return .purple
        case "Electerm": return .blue
        case "WindTerm": return .green
        case "CSV": return .secondary
        default: return .secondary
        }
    }

    // Cache non-duplicate IDs
    private var nonDuplicateSSHIDs: Set<UUID> { Set(sshEntries.filter { !existingNames.contains($0.alias) }.map(\.id)) }
    private var nonDuplicateExternalIDs: Set<UUID> { Set(externalHosts.filter { !existingNames.contains($0.0.name) }.map(\.0.id)) }

    private var footer: some View {
        HStack(spacing: AppStyle.spacingM) {
            Button(selectedCount == totalCount ? i18n.t(.deselectAll) : i18n.t(.selectAll)) {
                if selectedCount == totalCount { selectedSSH.removeAll(); selectedExternal.removeAll() }
                else {
                    selectedSSH = nonDuplicateSSHIDs
                    selectedExternal = nonDuplicateExternalIDs
                }
            }.disabled(totalCount == 0)
            Button(i18n.t(.chooseFile)) { promptForFile() }
            Spacer()
            Button(i18n.t(.cancel)) { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                performImport()
            } label: {
                if isImporting { ProgressView().controlSize(.small) } else { Text(i18n.t(.importSessions)) }
            }.disabled(selectedCount == 0 || isImporting).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }.padding()
    }

    private func toggleSSH(_ id: UUID) { if selectedSSH.contains(id) { selectedSSH.remove(id) } else { selectedSSH.insert(id) } }
    private func toggleExternal(_ id: UUID) { if selectedExternal.contains(id) { selectedExternal.remove(id) } else { selectedExternal.insert(id) } }

    private func load() {
        if let all = try? modelContext.fetch(FetchDescriptor<HostItem>()) { existingNames = Set(all.map(\.name)) }
        // SSH config
        do { sshEntries = try SSHConfigParser.parse() } catch { sshEntries = [] }
        selectedSSH = Set(sshEntries.filter { !existingNames.contains($0.alias) }.map(\.id))

        // External auto-detect (all easy importers)
        var discovered: [(HostItem, String)] = []
        for importer in importers {
            for url in importer.discoverDefaultLocations() {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let exists = FileManager.default.fileExists(atPath: url.path)
                if !exists && !isDir { continue }
                // For directories (WindTerm/iTerm dynamic), try import
                do {
                    let hosts = try importer.importSessions(from: url)
                    let filtered = hosts.filter { !discovered.map(\.0.name).contains($0.name) }
                    discovered.append(contentsOf: filtered.map { ($0, importer.name) })
                } catch { continue }
                // Only first successful file per importer to avoid duplicates
                if discovered.contains(where: { $0.1 == importer.name }) { break }
            }
        }
        externalHosts = discovered
        selectedExternal = Set(externalHosts.filter { !existingNames.contains($0.0.name) }.map(\.0.id))
        importError = nil
    }

    private func promptForFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.json, .commaSeparatedText, .plainText, .propertyList]
        // Add yaml, plist, csv, wsession
        if let yaml = UTType(filenameExtension: "yaml") { types.append(yaml) }
        if let yml = UTType(filenameExtension: "yml") { types.append(yml) }
        if let plist = UTType(filenameExtension: "plist") { types.append(plist) }
        if let csv = UTType(filenameExtension: "csv") { types.append(csv) }
        if let wsessionType = UTType(filenameExtension: "wsession") { types.append(wsessionType) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            autoImport(from: url)
        }
    }

    private func autoImport(from url: URL) {
        // Try each importer in order (specific → generic)
        for importer in importers {
            // Quick extension check, but also try generic even if extension mismatched
            do {
                let hosts = try importer.importSessions(from: url)
                if !hosts.isEmpty {
                    // Merge, avoid duplicates by name
                    var added: [(HostItem, String)] = []
                    for hostItem in hosts where !externalHosts.map(\.0.name).contains(hostItem.name) && !existingNames.contains(hostItem.name) {
                        added.append((hostItem, importer.name))
                    }
                    // If all were duplicates but we still got hosts, show them (let UI show duplicate badge)
                    if added.isEmpty, !hosts.isEmpty {
                        added = hosts.map { ($0, importer.name) }
                    }
                    externalHosts.append(contentsOf: added)
                    selectedExternal.formUnion(added.filter { !existingNames.contains($0.0.name) }.map(\.0.id))
                    importError = nil
                    return
                }
            } catch { continue }
        }
        // Fallback: try SSH config parser if file looks like ssh config
        if let text = try? String(contentsOf: url, encoding: .utf8), text.contains("Host ") {
            do {
                let entries = try SSHConfigParser.parse(contentsOfFile: url.path)
                let newEntries = entries.filter { !sshEntries.map(\.alias).contains($0.alias) }
                sshEntries.append(contentsOf: newEntries)
                selectedSSH.formUnion(newEntries.filter { !existingNames.contains($0.alias) }.map(\.id))
                importError = nil
                return
            } catch {}
        }
        importError = "无法识别文件格式，请选择 SSH Config / Tabby / iTerm2 / Electerm / WindTerm / CSV"
    }

    private func performImport() {
        isImporting = true
        var created = 0, skipped = 0
        // SSH
        for entry in sshEntries where selectedSSH.contains(entry.id) {
            if existingNames.contains(entry.alias) { skipped += 1; continue }
            let host = entry.hostname ?? entry.alias
            let port = Int(entry.port ?? 22)
            let user = entry.user ?? NSUserName()
            let item = HostItem(name: entry.alias, host: host, port: port, username: user, authType: .privateKey, privateKeyPEM: loadKey(entry.identityFile))
            modelContext.insert(item)
            existingNames.insert(entry.alias); created += 1
        }
        // External
        for (hostItem, _) in externalHosts where selectedExternal.contains(hostItem.id) {
            if existingNames.contains(hostItem.name) { skipped += 1; continue }
            modelContext.insert(hostItem)
            existingNames.insert(hostItem.name); created += 1
        }
        try? modelContext.save()
        resultCreated = created; resultSkipped = skipped
        isImporting = false; showResult = true
    }

    private func loadKey(_ path: String?) -> String? {
        guard let path else { return nil }
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let fileData = FileManager.default.contents(atPath: expandedPath), let fileContent = String(data: fileData, encoding: .utf8) else { return nil }
        return fileContent
    }
}


