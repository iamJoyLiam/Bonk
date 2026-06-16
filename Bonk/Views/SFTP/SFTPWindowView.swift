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
    @State private var localPath: String = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    @State private var localFiles: [LocalFileEntry] = []
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
            // Header — matches SFTPBrowserView.header
            HStack {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.blue)
                Text(i18n.t(.localFiles))
                    .font(.headline)

                Spacer()

                Button { loadLocalFiles() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(i18n.t(.refresh))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Path bar — matches SFTPBrowserView.pathBar
            HStack(spacing: 4) {
                Button { goUpLocal() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(localPath == "/")

                Text(localPath)
                    .font(.system(size: 11).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))

            Divider()

            // File list — uses LocalFileRow matching SFTPFileRow
            List(localFiles) { file in
                LocalFileRow(file: file)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if file.isDirectory {
                            localPath = file.path
                            loadLocalFiles()
                        }
                    }
                    .contextMenu {
                        if !file.isDirectory {
                            Button { uploadLocalFile(file) } label: {
                                Label(i18n.t(.upload), systemImage: "arrow.up.doc")
                            }
                        }
                        if file.isDirectory {
                            Button {
                                localPath = file.path
                                loadLocalFiles()
                            } label: {
                                Label(i18n.t(.open), systemImage: "folder")
                            }
                        }
                        Divider()
                        Button {
                            NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: localPath)
                        } label: {
                            Label(i18n.t(.showInFinder), systemImage: "finder")
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

    private func localFileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh", "py", "rb", "pl": return "terminal"
        case "yml", "yaml", "json", "xml", "toml": return "doc.text"
        case "txt", "log", "md": return "doc.plaintext"
        case "jpg", "jpeg", "png", "gif", "svg": return "photo"
        case "zip", "tar", "gz", "bz2", "xz": return "archivebox"
        case "conf", "cfg", "ini", "env": return "gearshape"
        default: return "doc"
        }
    }

    private func localFileIconColor(_ name: String) -> Color {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh", "py", "rb": return .green
        case "yml", "yaml", "json", "xml": return .orange
        case "log", "txt": return .gray
        case "jpg", "jpeg", "png", "gif": return .purple
        default: return .secondary
        }
    }

    private func uploadLocalFile(_ file: LocalFileEntry) {
        guard let sftp = sessionManager.activeTab?.session?.sftpService else { return }
        Task {
            do {
                try await sftp.upload(URL(fileURLWithPath: file.path))
            } catch {
                sftp.errorMessage = error.localizedDescription
            }
        }
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

// MARK: - Local File Row (matches SFTPFileRow layout)

struct LocalFileRow: View {
    let file: LocalFileEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 12))
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            if file.isDirectory {
                                Text("Folder")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            } else {
                                let ext = (file.name as NSString).pathExtension
                                if !ext.isEmpty {
                                    Text(ext.uppercased())
                                        .font(.system(size: 9).monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                                Text(formatSize(file.size))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if file.isDirectory { return "folder.fill" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh", "py", "rb", "pl": return "terminal"
        case "yml", "yaml", "json", "xml", "toml": return "doc.text"
        case "txt", "log", "md": return "doc.plaintext"
        case "jpg", "jpeg", "png", "gif", "svg": return "photo"
        case "zip", "tar", "gz", "bz2", "xz": return "archivebox"
        case "conf", "cfg", "ini", "env": return "gearshape"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        if file.isDirectory { return .blue }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh", "py", "rb": return .green
        case "yml", "yaml", "json", "xml": return .orange
        case "log", "txt": return .gray
        case "jpg", "jpeg", "png", "gif": return .purple
        default: return .secondary
        }
    }

    private func formatSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1024 / 1024) }
        return String(format: "%.1f GB", Double(bytes) / 1024 / 1024 / 1024)
    }
}
