//
//  SSHConfigImportView.swift
//  Bonk
//
//  Import preview UI for SSH config entries.
//

import os.log
import SwiftData
import SwiftUI

// MARK: - Import View

/// Preview and import SSH config entries into Bonk.
struct SSHConfigImportView: View {
    let modelContext: ModelContext
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [SSHConfigEntry] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var importResult: ImportResultData?
    @State private var isImporting = false
    @State private var showResult = false

    /// Existing host names for duplicate detection.
    @State private var existingHosts: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Content
            if entries.isEmpty {
                emptyState
            } else {
                entryList
            }

            Divider()

            // Footer
            footerSection
        }
        .frame(minWidth: AppStyle.settingsWindowHeight, minHeight: AppStyle.quickConnectWidth)
        .onAppear {
            loadExistingHosts()
            // Parse SSH config entries
            do {
                entries = try SSHConfigParser.parse()
            } catch {
                Log.general.error("Failed to parse SSH config: \(error.localizedDescription)")
            }
            // Select all by default
            selectedIDs = Set(entries.map(\.id))
        }
        .alert(i18n.t(.importResult), isPresented: $showResult) {
            Button(i18n.t(.ok)) {
                dismiss()
            }
        } message: {
            if let result = importResult {
                Text(i18n.tr(.importSuccessMessage, args: result.created, result.skipped, result.errors.count))
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text(i18n.t(.importSSHConfig))
                    .font(.headline)
                Spacer()
                Text("\(entries.count) \(i18n.t(.hostsFound))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(i18n.t(.importSSHConfigDescription))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: AppStyle.fontDisplay))
                .foregroundStyle(.secondary)
            Text(i18n.t(.noSSHConfigEntries))
                .font(.headline)
            Text(i18n.t(.noSSHConfigEntriesDescription))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Entry List

    private var entryList: some View {
        List(selection: $selectedIDs) {
            ForEach(entries) { entry in
                entryRow(entry)
                    .tag(entry.id)
            }
        }
        .listStyle(.bordered)
    }

    private func entryRow(_ entry: SSHConfigEntry) -> some View {
        HStack {
            // Selection checkbox
            Image(systemName: selectedIDs.contains(entry.id)
                ? "checkmark.circle.fill"
                : "circle"
            )
            .foregroundStyle(selectedIDs.contains(entry.id) ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.alias)
                        .font(.body)
                        .fontWeight(.medium)

                    if existingHosts.contains(entry.alias) {
                        Text(i18n.t(.duplicate))
                            .font(.caption2)
                            .padding(.horizontal, AppStyle.spacingS)
                            .padding(.vertical, AppStyle.spacingXXS)
                            .background(.orange.opacity(AppStyle.opacityOverlayLight))
                            .cornerRadius(4)
                    }
                }

                HStack(spacing: 12) {
                    if let hostname = entry.hostname {
                        Label(hostname, systemImage: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let port = entry.port, port != 22 {
                        Label("\(port)", systemImage: "number")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let user = entry.user {
                        Label(user, systemImage: "person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Show forwarded ports
                if !entry.localForwards.isEmpty || !entry.remoteForwards.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(entry.localForwards, id: \.localPort) { fwd in
                            Text("L:\(fwd.localPort)→\(fwd.remoteHost):\(fwd.remotePort)")
                                .font(.caption2)
                                .padding(.horizontal, AppStyle.spacingXS)
                                .padding(.vertical, AppStyle.spacingXXS)
                                .background(.blue.opacity(AppStyle.opacityOverlaySubtle))
                                .cornerRadius(3)
                        }
                        ForEach(entry.remoteForwards, id: \.localPort) { fwd in
                            Text("R:\(fwd.remotePort)→\(fwd.remoteHost):\(fwd.localPort)")
                                .font(.caption2)
                                .padding(.horizontal, AppStyle.spacingXS)
                                .padding(.vertical, AppStyle.spacingXXS)
                                .background(.green.opacity(AppStyle.opacityOverlaySubtle))
                                .cornerRadius(3)
                        }
                    }
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if selectedIDs.contains(entry.id) {
                    selectedIDs.remove(entry.id)
                } else {
                    selectedIDs.insert(entry.id)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            // Select All / Deselect All
            Button {
                if selectedIDs.count == entries.count {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(entries.map(\.id))
                }
            } label: {
                Text(selectedIDs.count == entries.count
                    ? i18n.t(.deselectAll)
                    : i18n.t(.selectAll)
                )
            }
            .disabled(entries.isEmpty)

            Spacer()

            // Cancel
            Button(i18n.t(.cancel)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            // Import
            Button {
                performImport()
            } label: {
                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(i18n.t(.ok))
                }
            }
            .disabled(selectedIDs.isEmpty || isImporting)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Actions

    private func loadExistingHosts() {
        let descriptor = FetchDescriptor<HostItem>()
        if let hosts = try? modelContext.fetch(descriptor) {
            existingHosts = Set(hosts.map(\.name))
        }
    }

    private func performImport() {
        isImporting = true

        let entriesToImport = entries.filter { selectedIDs.contains($0.id) }
        var created = 0
        var skipped = 0
        var errors: [(SSHConfigEntry, Error)] = []

        for entry in entriesToImport {
            // Check for duplicate
            if existingHosts.contains(entry.alias) {
                skipped += 1
                continue
            }

            do {
                try importEntry(entry)
                created += 1
                existingHosts.insert(entry.alias) // Prevent duplicates in same batch
            } catch {
                errors.append((entry, error))
            }
        }

        importResult = ImportResultData(
            created: created,
            skipped: skipped,
            errors: errors
        )
        isImporting = false
        showResult = true
    }

    private func importEntry(_ entry: SSHConfigEntry) throws {
        // Resolve hostname
        let hostname = entry.hostname ?? entry.alias
        let port = Int(entry.port ?? 22)
        let username = entry.user ?? NSUserName()

        // Create HostItem with private key
        let hostItem = HostItem(
            name: entry.alias,
            host: hostname,
            port: port,
            username: username,
            authType: .privateKey,
            privateKeyPEM: loadPrivateKeyContent(from: entry.identityFile)
        )

        // Insert the host
        modelContext.insert(hostItem)
        try modelContext.save()
    }

    private func loadPrivateKeyContent(from path: String?) -> String? {
        guard let path else { return nil }
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expandedPath),
              let content = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return content
    }
}

// MARK: - Import Result

struct ImportResultData {
    var created: Int
    var skipped: Int
    var errors: [(SSHConfigEntry, Error)]
}
