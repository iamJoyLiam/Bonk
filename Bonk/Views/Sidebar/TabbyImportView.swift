//
//  TabbyImportView.swift
//  Bonk
//
//  Import Tabby SSH profiles.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TabbyImportView: View {
    let modelContext: ModelContext
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss

    @State private var hosts: [HostItem] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var showResult = false
    @State private var importResult: ImportSummary?
    @State private var existingNames: Set<String> = []

    struct ImportSummary { var created: Int; var skipped: Int }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            if let msg = errorMessage {
                errorSection(msg)
            } else if hosts.isEmpty {
                emptyState
            } else {
                hostList
            }
            Divider()
            footerSection
        }
        .frame(minWidth: 520, minHeight: 380)
        .onAppear { loadExisting(); discoverOrPrompt() }
        .alert("Import", isPresented: $showResult) {
            Button("OK") { dismiss() }
        } message: {
            if let r = importResult { Text("\(r.created) imported, \(r.skipped) skipped") }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil && hosts.isEmpty)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "square.and.arrow.down").font(.title2).foregroundStyle(.blue)
                Text("Import Tabby").font(.headline)
                Spacer()
                Text("\(hosts.count) hosts").font(.caption).foregroundStyle(.secondary)
            }
            Text("Select Tabby JSON/YAML file or auto-discover from ~/.config/tabby/config.yaml")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No Tabby sessions").font(.headline)
            Text(errorMessage ?? "Choose a Tabby config file to import")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose File") { promptForFile() }
                .buttonStyle(.borderedProminent)
            if let auto = TabbyImporter().discoverDefaultLocations().first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                Text("Found: \(auto.path)").font(.caption2).foregroundStyle(.tertiary)
                Button("Import from \(auto.lastPathComponent)") { load(from: auto) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func errorSection(_ msg: String) -> some View {
        HStack { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); Text(msg).font(.caption).foregroundStyle(.secondary) }.padding()
    }

    private var hostList: some View {
        List(selection: $selectedIDs) {
            ForEach(hosts, id: \.id) { h in
                HStack {
                    Image(systemName: selectedIDs.contains(h.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedIDs.contains(h.id) ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(h.name).font(.body.weight(.medium))
                            if existingNames.contains(h.name) {
                                Text("duplicate").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.orange.opacity(0.2)).cornerRadius(4)
                            }
                        }
                        HStack(spacing: 8) {
                            Label(h.host, systemImage: "globe").font(.caption).foregroundStyle(.secondary)
                            Label("\(h.port)", systemImage: "number").font(.caption).foregroundStyle(.secondary)
                            Label(h.username, systemImage: "person").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }.contentShape(Rectangle()).onTapGesture {
                    if selectedIDs.contains(h.id) { selectedIDs.remove(h.id) } else { selectedIDs.insert(h.id) }
                }.tag(h.id)
            }
        }.listStyle(.bordered)
    }

    private var footerSection: some View {
        HStack {
            Button(selectedIDs.count == hosts.count ? "Deselect All" : "Select All") {
                if selectedIDs.count == hosts.count { selectedIDs.removeAll() } else { selectedIDs = Set(hosts.map(\.id)) }
            }.disabled(hosts.isEmpty)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Choose File") { promptForFile() }
            Button {
                performImport()
            } label: {
                if isImporting { ProgressView().controlSize(.small) } else { Text("Import") }
            }.disabled(selectedIDs.isEmpty || isImporting).keyboardShortcut(.defaultAction)
        }.padding()
    }

    private func loadExisting() {
        if let all = try? modelContext.fetch(FetchDescriptor<HostItem>()) {
            existingNames = Set(all.map(\.name))
        }
    }

    private func discoverOrPrompt() {
        let importer = TabbyImporter()
        for url in importer.discoverDefaultLocations() where FileManager.default.fileExists(atPath: url.path) {
            load(from: url); return
        }
        // No auto file, wait for user to choose
    }

    private func promptForFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json, UTType.yaml, UTType(filenameExtension: "yml") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(from: url) }
    }

    private func load(from url: URL) {
        do {
            let importer = TabbyImporter()
            let items = try importer.importSessions(from: url)
            hosts = items
            selectedIDs = Set(items.map(\.id))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            hosts = []
        }
    }

    private func performImport() {
        isImporting = true
        var created = 0, skipped = 0
        for h in hosts where selectedIDs.contains(h.id) {
            if existingNames.contains(h.name) { skipped += 1; continue }
            modelContext.insert(h)
            // Credentials already stored via HostItem init (Keychain)
            existingNames.insert(h.name)
            created += 1
        }
        try? modelContext.save()
        importResult = ImportSummary(created: created, skipped: skipped)
        isImporting = false
        showResult = true
    }
}
