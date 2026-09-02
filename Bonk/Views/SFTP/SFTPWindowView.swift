//
//  SFTPWindowView.swift
//  Bonk
//
//  SFTP file browser as an independent macOS window.
//  Left: local files, Right: remote files, Bottom: transfer progress.
//

import AppKit
import SwiftData
import SwiftUI

struct SFTPWindowView: View {
    @Environment(I18n.self) var i18n
    @Bindable var sessionManager: SessionManager
    @Query private var allPreferences: [UserPreferences]
    @State private var localPath: String = "/"
    @State private var localFiles: [LocalFileEntry] = []
    @State private var selectedRemote: SFTPFileEntry?
    @State private var localSelection: Set<UUID> = []
    @State private var isEditingLocal = false
    @State private var editingLocal = ""
    @FocusState private var isLocalFocused: Bool
    // Overwrite dialog state
    @State private var pendingUploadURL: URL?
    @State private var showOverwriteAlert = false
    @State private var overwriteAlways = false

    private var preferences: UserPreferences {
        allPreferences.first ?? UserPreferences()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let tab = sessionManager.activeTab, tab.session?.sshService != nil {
                // Dual pane: local (left) + remote (right)
                HSplitView {
                    // Left: Local files
                    localFilePanel
                        .frame(minWidth: AppStyle.sftpPaneMinWidth)

                    // Right: Remote files
                    SFTPBrowserView(tab: tab, onUpload: { url in
                        Task { await checkAndUpload(url) }
                    }, onDownloadCompleted: {
                        loadLocalFiles()
                    })
                    .frame(minWidth: AppStyle.sftpPaneMinWidth)
                }

                // Bottom: Transfer progress
                if let sftp = tab.session?.sftpService, !sftp.transfers.isEmpty {
                    Divider()
                    transferPanel(sftp: sftp)
                }
                // Zmodem — only when enabled in Settings
                if preferences.isZmodemEnabled ?? false {
                    if let zmodem = tab.session?.ptySession?.zmodemHandler, zmodem.state != .idle {
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.arrow.down.circle.fill").foregroundStyle(.purple)
                            Text("\(i18n.t(.fileTransfer)) \(String(describing: zmodem.state))")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(i18n.t(.cancel)) { tab.session?.ptySession?.cancelZmodem() }
                                .buttonStyle(.bordered).controlSize(.small)
                        }.padding(.horizontal, AppStyle.spacingL).padding(.vertical, 4)
                    } else if tab.session?.ptySession != nil {
                        Divider()
                        HStack(spacing: 8) {
                            Button { Task { tab.session?.ptySession?.startZmodemReceive() } } label: { Label(i18n.t(.receiveFile), systemImage: "arrow.down.doc") }
                                .buttonStyle(.bordered).controlSize(.small)
                            Button { showZmodemSendPicker(for: tab) } label: { Label(i18n.t(.sendFile), systemImage: "arrow.up.doc") }
                                .buttonStyle(.bordered).controlSize(.small)
                            Spacer()
                            Text(i18n.t(.fileTransfer)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, AppStyle.spacingL).padding(.vertical, 4)
                    }
                }
            } else {
                ContentUnavailableView(
                    i18n.t(.noActiveSession),
                    systemImage: "folder.badge.questionmark",
                    description: Text(i18n.t(.connectToHostFirst))
                )
            }
        }
        .confirmationDialog(
            pendingUploadURL.map { i18n.tr(.fileExists, args: $0.lastPathComponent) } ?? "",
            isPresented: $showOverwriteAlert
        ) {
            Button(i18n.t(.overwrite)) {
                if let url = pendingUploadURL {
                    pendingUploadURL = nil
                    showOverwriteAlert = false
                    Task { await performUpload(url) }
                }
            }
            Button(i18n.t(.alwaysOverwrite)) {
                if let url = pendingUploadURL {
                    overwriteAlways = true
                    preferences.sftpOverwriteAlways = true // Sync to settings
                    pendingUploadURL = nil
                    showOverwriteAlert = false
                    Task { await performUpload(url) }
                }
            }
            Button(i18n.t(.cancel), role: .cancel) {
                pendingUploadURL = nil
                showOverwriteAlert = false
            }
        }
        .frame(minWidth: 800, minHeight: AppStyle.settingsWindowHeight)
        .onAppear {
            let defaultPath = preferences.sftpDefaultLocalPath
                ?? (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
            localPath = defaultPath
            loadLocalFiles()
        }
    }

    // MARK: - Local File Panel

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
            .padding(.horizontal, AppStyle.spacingL)
            .padding(.vertical, AppStyle.spacingM)

            Divider()

            HStack(spacing: 6) {
                Button { goUpLocal() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: AppStyle.fontSmall, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(localPath == "/" || isEditingLocal)

                TextField("", text: $editingLocal, prompt: Text(localPath).font(.system(size: AppStyle.fontSmall).monospaced()))
                    .font(.system(size: AppStyle.fontSmall).monospaced())
                    .textFieldStyle(.plain)
                    .focused($isLocalFocused)
                    .disabled(!isEditingLocal)
                    .onChange(of: localPath) { _, newPath in if !isEditingLocal { editingLocal = newPath } }
                    .onAppear { editingLocal = localPath }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { guard !isEditingLocal else { return }; editingLocal = localPath; isEditingLocal = true; isLocalFocused = true }
                    .onSubmit { commitLocal() }
                    .onExitCommand { isEditingLocal = false }

                Button {
                    if isEditingLocal { commitLocal() } else { editingLocal = localPath; isEditingLocal = true; isLocalFocused = true }
                } label: {
                    Image(systemName: isEditingLocal ? "arrow.right.circle.fill" : "arrow.right.circle")
                        .font(.system(size: AppStyle.fontMedium))
                        .foregroundStyle(isEditingLocal ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .help(isEditingLocal ? "Go" : "Edit")
            }
            .padding(.horizontal, AppStyle.spacingL)
            .padding(.vertical, AppStyle.spacingS)
            .background(.quaternary.opacity(AppStyle.opacityOverlay))

            Divider()

            // File list — uses LocalFileRow matching SFTPFileRow, supports Shift multi-select
            List(localFiles, id: \.id, selection: $localSelection) { file in
                LocalFileRow(file: file)
                    .environment(i18n)
                    .tag(file.id)
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
            .animation(nil, value: localFiles)
        }
    }

    // MARK: - Transfer Panel

    private func transferPanel(sftp: SFTPService) -> some View {
        VStack(spacing: 4) {
            ForEach(sftp.transfers) { transfer in
                HStack(spacing: 8) {
                    let iconName = transfer.isCancelled
                        ? "xmark.circle.fill"
                        : (transfer.isComplete ? "checkmark.circle.fill" : "arrow.down.circle")
                    Image(systemName: iconName)
                        .font(.system(size: AppStyle.fontBody))
                        .foregroundStyle(
                            transfer.isCancelled ? .orange : (transfer.isComplete ? .green : .blue)
                        )

                    Text(transfer.filename)
                        .font(.system(size: AppStyle.fontSmall))
                        .lineLimit(1)

                    if transfer.isActive {
                        if let progress = transfer.progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                // Elegant: 1:1 model + 60 FPS display + 0.5s interpolation for 10Gbps bursts
                                .animation(.easeOut(duration: 0.5), value: progress)
                                .transaction { t in t.animation = .easeOut(duration: 0.5) }
                        } else {
                            // Unknown size: indeterminate + bytes (never fake %)
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }

                    // Bytes label — for known shows "500 MB / 600 MB" style via progress, for unknown just MB
                    if transfer.isActive || transfer.isComplete {
                        let bytesText: String = {
                            let mb = Double(transfer.transferredBytes) / (1024*1024)
                            if let total = transfer.totalBytes, total > 0 {
                                let totalMB = Double(total) / (1024*1024)
                                if totalMB >= 1024 { return String(format: "%.1f/%.1f GB", mb/1024, totalMB/1024) }
                                return String(format: "%.1f/%.1f MB", mb, totalMB)
                            } else {
                                if mb >= 1024 { return String(format: "%.1f GB", mb/1024) }
                                return String(format: "%.1f MB", mb)
                            }
                        }()
                        Text(bytesText)
                            .font(.system(size: AppStyle.fontCaption).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let error = transfer.error {
                        Text(error)
                            .font(.system(size: AppStyle.fontCaption))
                            .foregroundStyle(.red)
                    }

                    // Cancel button for active transfers
                    if transfer.isActive {
                        Button {
                            sftp.cancelTransfer(transfer.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: AppStyle.fontBody))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    // Remove button for completed/failed transfers
                    if transfer.isComplete || transfer.error != nil {
                        Button {
                            sftp.removeTransfer(transfer.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: AppStyle.fontBody))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingM)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Helpers

    private func loadLocalFiles() {
        let path = localPath
        Task { @MainActor in
            let sorted: [LocalFileEntry] = await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else { return [] }
                let files: [LocalFileEntry] = contents.compactMap { name -> LocalFileEntry? in
                    let fullPath = (path as NSString).appendingPathComponent(name)
                    guard let attrs = try? fileManager.attributesOfItem(atPath: fullPath) else { return nil }
                    let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
                    let size = attrs[.size] as? UInt64 ?? 0
                    let mtime = attrs[.modificationDate] as? Date
                    return LocalFileEntry(name: name, path: fullPath, isDirectory: isDir, size: size, modifiedAt: mtime)
                }
                return files.sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }.value
            guard self.localPath == path else { return }
            self.localFiles = sorted
        }
    }

    private func goUpLocal() {
        let parentPath = (localPath as NSString).deletingLastPathComponent
        localPath = parentPath.isEmpty ? "/" : parentPath
        loadLocalFiles()
    }

    private func commitLocal() {
        let trimmedText = editingLocal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { isEditingLocal = false; return }
        let expandedPath = (trimmedText as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDir), isDir.boolValue else {
            // keep at current, stay editing for correction
            isLocalFocused = true
            return
        }
        isEditingLocal = false; isLocalFocused = false
        localPath = expandedPath
        loadLocalFiles()
    }

    private func uploadLocalFile(_ file: LocalFileEntry) {
        let url = URL(fileURLWithPath: file.path)
        Task { await checkAndUpload(url) }
    }

    private func checkAndUpload(_ url: URL) async {
        guard let sftp = sessionManager.activeTab?.session?.sftpService else { return }

        // Check if overwrite is enabled in settings
        let overwriteEnabled = preferences.sftpOverwriteAlways ?? false

        if overwriteAlways || overwriteEnabled {
            await performUpload(url)
            return
        }

        let basePath = sftp.currentPath.hasSuffix("/") ? sftp.currentPath : sftp.currentPath + "/"
        let remotePath = basePath + url.lastPathComponent
        switch await sftp.fileExists(at: remotePath) {
        case true:
            pendingUploadURL = url
            showOverwriteAlert = true
        case false:
            await performUpload(url)
        case nil:
            // fileExists check failed (SFTP interrupted) — allow upload, server will handle it
            // Don't show placeholder %@, try to ensure SFTP and proceed
            if sessionManager.activeTab?.session?.sftpService == nil {
                _ = await sessionManager.activeTab?.session?.ensureSFTP()
            }
            await performUpload(url)
        }
    }

    private func performUpload(_ url: URL) async {
        guard let sftp = sessionManager.activeTab?.session?.sftpService else { return }
        do {
            // upload returns a lazy AsyncThrowingStream — it must be consumed
            // for the transfer to start (and its progress to be reported).
            for try await _ in sftp.upload(url) {}
        } catch {
            sftp.errorMessage = error.localizedDescription
        }
    }

    private func showZmodemSendPicker(for tab: TerminalTab) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { @MainActor in
                if let pty = tab.session?.ptySession {
                    if pty.zmodemHandler == nil { pty.setupZmodem() }
                    pty.startZmodemSend(files: urls)
                }
            }
        }
    }

}
