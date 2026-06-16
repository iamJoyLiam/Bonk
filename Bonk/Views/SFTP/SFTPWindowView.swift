//
//  SFTPWindowView.swift
//  Bonk
//
//  SFTP file browser as an independent macOS window.
//  Left: local files, Right: remote files, Bottom: transfer progress.
//

import SwiftUI

struct SFTPWindowView: View {
    @Environment(I18n.self) var i18n
    @Bindable var sessionManager: SessionManager
    @State private var localPath: String = NSHomeDirectory()
    @State private var localFiles: [LocalFileEntry] = []
    @State private var selectedLocal: LocalFileEntry?
    @State private var selectedRemote: SFTPFileEntry?

    var body: some View {
        VStack(spacing: 0) {
            if let tab = sessionManager.activeTab, let sftp = tab.session?.sftpService {
                // Dual pane: local (left) + remote (right)
                HSplitView {
                    // Left: Local files
                    localFilePanel
                        .frame(minWidth: 250)

                    // Right: Remote files
                    SFTPBrowserView(tab: tab)
                        .frame(minWidth: 250)
                }

                // Bottom: Transfer progress
                if !sftp.transfers.isEmpty {
                    Divider()
                    transferPanel(sftp: sftp)
                }
            } else {
                ContentUnavailableView(
                    i18n.t(.noActiveSession),
                    systemImage: "folder.badge.questionmark",
                    description: Text(i18n.t(.connectToHostFirst))
                )
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            loadLocalFiles()
            if let tab = sessionManager.activeTab, tab.session?.sftpService == nil {
                Task { _ = await ensureSFTP(for: tab) }
            }
        }
    }

    // MARK: - Local File Panel

    @ViewBuilder
    private var localFilePanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.blue)
                Text(i18n.t(.localFiles))
                    .font(.headline)
                Spacer()
                Button {
                    loadLocalFiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Path bar
            HStack(spacing: 4) {
                Button {
                    goUpLocal()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11))
                }
                .disabled(localPath == "/")

                Text(localPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // File list
            List(localFiles, selection: $selectedLocal) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                        .font(.system(size: 14))
                        .foregroundStyle(file.isDirectory ? .blue : .secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 12))
                        if !file.isDirectory {
                            Text(formatSize(file.size))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if file.isDirectory {
                        localPath = file.path
                        loadLocalFiles()
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Transfer Panel

    @ViewBuilder
    private func transferPanel(sftp: SFTPService) -> some View {
        VStack(spacing: 4) {
            ForEach(sftp.transfers) { transfer in
                HStack(spacing: 8) {
                    Image(systemName: transfer.isComplete ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(transfer.isComplete ? .green : .blue)

                    Text(transfer.filename)
                        .font(.system(size: 11))
                        .lineLimit(1)

                    if !transfer.isComplete {
                        ProgressView(value: transfer.progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 120)
                    }

                    Spacer()

                    if let error = transfer.error {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Helpers

    private func loadLocalFiles() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: localPath) else { return }

        localFiles = contents.compactMap { name -> LocalFileEntry? in
            let path = (localPath as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
            let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
            let size = attrs[.size] as? UInt64 ?? 0
            return LocalFileEntry(name: name, path: path, isDirectory: isDir, size: size)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func goUpLocal() {
        localPath = (localPath as NSString).deletingLastPathComponent
        loadLocalFiles()
    }

    private func formatSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1024 / 1024) }
        return String(format: "%.1f GB", Double(bytes) / 1024 / 1024 / 1024)
    }

    private func ensureSFTP(for tab: TerminalTab) async -> SFTPService? {
        if let existing = tab.session?.sftpService { return existing }
        guard let sshService = tab.session?.sshService else { return nil }
        let sftp = SFTPService()
        do {
            try await sftp.connect(using: sshService)
            tab.session?.sftpService = sftp
            return sftp
        } catch {
            return nil
        }
    }
}

// MARK: - Local File Entry

struct LocalFileEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
}
