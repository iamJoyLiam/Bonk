//
//  SFTPBrowserView.swift
//  Bonk
//

import os.log
import SwiftUI
import UniformTypeIdentifiers

/// SFTP file browser panel.
struct SFTPBrowserView: View {
    @Environment(I18n.self) var i18n
    let tab: TerminalTab
    /// Optional upload handler with overwrite check. If nil, uploads directly.
    var onUpload: ((URL) -> Void)?
    var onDownloadCompleted: (() -> Void)?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDeleteEntry: SFTPFileEntry?
    @State private var selection: Set<String> = []
    @State private var pendingDeleteIDs: Set<String> = []
    @State private var isEditingPath = false
    @State private var editingPath = ""
    @FocusState private var isPathFocused: Bool
    @State private var toast: String?

    private var sftpService: SFTPService? {
        tab.session?.sftpService
    }

    private var isConnected: Bool {
        sftpService != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pathBar
            Divider()

            // File list
            if let service = sftpService {
                if service.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = service.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(i18n.t(.retry)) {
                            Task {
                                do { try await service.listDirectory() } catch {
                                    service.errorMessage = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    fileList(service)
                }
            } else if tab.session?.isSFTPConnecting == true {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = tab.session?.sftpErrorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(i18n.t(.retry)) {
                        Task { await connectSFTP() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: AppStyle.fontHuge))
                        .foregroundStyle(.quaternary)
                    Text(i18n.t(.sftpNotConnected))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Button(i18n.t(.connect)) {
                        Task { await connectSFTP() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Transfer progress 已移至 SFTPWindowView 统一显示
        }
        .frame(minWidth: 240)
        .overlay(alignment: .top) {
            if let msg = toast {
                Text(msg)
                    .font(.system(size: AppStyle.fontSmall))
                    .padding(.horizontal, AppStyle.spacingL).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, AppStyle.spacingM)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toast)
        .alert(i18n.t(.newFolder), isPresented: $showNewFolder) {
            TextField(i18n.t(.newFolder), text: $newFolderName)
            Button(i18n.t(.create)) {
                guard !newFolderName.isEmpty, let service = sftpService else { return }
                Task {
                    do { try await service.createDirectory(name: newFolderName) } catch {
                        service.errorMessage = error.localizedDescription
                    }
                }
                newFolderName = ""
            }
            Button(i18n.t(.cancel), role: .cancel) { newFolderName = "" }
        }
        .task(id: tab.id) {
            if tab.session?.sshService != nil, tab.session?.sftpService == nil {
                await connectSFTP()
            }
        }
        .alert(i18n.t(.delete), isPresented: deleteEntryAlertBinding) {
            Button(i18n.t(.delete), role: .destructive) {
                if let entry = pendingDeleteEntry, let service = sftpService {
                    Task {
                        do { try await service.delete(entry) } catch {
                            service.errorMessage = error.localizedDescription
                        }
                        selection.removeAll()
                    }
                }
                pendingDeleteEntry = nil
            }
            Button(i18n.t(.cancel), role: .cancel) { pendingDeleteEntry = nil }
        } message: {
            if let entry = pendingDeleteEntry {
                Text(i18n.tr(.deleteConfirm, args: entry.name))
            }
        }
        .alert(i18n.t(.delete), isPresented: deleteBatchAlertBinding) {
            Button(i18n.t(.delete), role: .destructive) {
                if let service = sftpService {
                    let ids = pendingDeleteIDs
                    Task {
                        for id in ids {
                            if let e = service.entries.first(where: { $0.id == id }) {
                                try? await service.delete(e)
                            }
                        }
                        selection.removeAll()
                    }
                }
                pendingDeleteIDs.removeAll()
            }
            Button(i18n.t(.cancel), role: .cancel) { pendingDeleteIDs.removeAll() }
        } message: {
            Text(i18n.tr(.deleteConfirm, args: "\(pendingDeleteIDs.count) items"))
        }
    }

    private var deleteEntryAlertBinding: Binding<Bool> {
        Binding(get: { pendingDeleteEntry != nil }, set: { if !$0 { pendingDeleteEntry = nil } })
    }

    private var deleteBatchAlertBinding: Binding<Bool> {
        Binding(get: { !pendingDeleteIDs.isEmpty }, set: { if !$0 { pendingDeleteIDs.removeAll() } })
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
            Text(i18n.t(.sftp))
                .font(.headline)

            Spacer()

            if isConnected {
                Button {
                    #if os(macOS)
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK {
                            for url in panel.urls {
                                if let onUpload {
                                    onUpload(url)
                                } else {
                                    Task {
                                        do {
                                            let stream = sftpService?.upload(url) ?? AsyncThrowingStream(Double.self) { $0.finish() }
                                        for try await _ in stream {}
                                        } catch {
                                            sftpService?.errorMessage = error.localizedDescription
                                        }
                                    }
                                }
                            }
                        }
                    #endif
                } label: {
                    Image(systemName: "arrow.up.doc.fill")
                }
                .buttonStyle(.borderless)
                .help(i18n.t(.uploadFile))

                Button {
                    showNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(i18n.t(.newFolder))

                Button {
                    Task {
                        do { try await sftpService?.listDirectory() } catch {
                            sftpService?.errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(i18n.t(.refresh))
            }
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingM)
    }

    // MARK: - Path Bar — single TextField, whole middle tappable, adaptive

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                Task {
                    do { try await sftpService?.goUp() } catch {
                        sftpService?.errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: AppStyle.fontSmall, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(sftpService?.currentPath == "/" || isEditingPath)

            TextField("", text: $editingPath, prompt: Text(sftpService?.currentPath ?? "/").font(.system(size: AppStyle.fontSmall).monospaced()))
                .font(.system(size: AppStyle.fontSmall).monospaced())
                .textFieldStyle(.plain)
                .focused($isPathFocused)
                .disabled(!isEditingPath)
                .onChange(of: sftpService?.currentPath ?? "/") { _, n in if !isEditingPath { editingPath = n } }
                .onAppear { editingPath = sftpService?.currentPath ?? "/" }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { guard !isEditingPath else { return }; editingPath = sftpService?.currentPath ?? "/"; isEditingPath = true; isPathFocused = true }
                .onSubmit { commitPath() }
                .onExitCommand { isEditingPath = false }

            Button {
                if isEditingPath { commitPath() } else { editingPath = sftpService?.currentPath ?? "/"; isEditingPath = true; isPathFocused = true }
            } label: {
                Image(systemName: isEditingPath ? "arrow.right.circle.fill" : "arrow.right.circle")
                    .font(.system(size: AppStyle.fontMedium))
                    .foregroundStyle(isEditingPath ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .help(isEditingPath ? "Go" : "Edit")
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingS)
        .background(.quaternary.opacity(AppStyle.opacityOverlay))
    }

    private func commitPath() {
        let t = editingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { isEditingPath = false; return }
        // immediately clear garbage, keep root visible
        editingPath = sftpService?.currentPath ?? "/"
        isEditingPath = false; isPathFocused = false
        Task {
            do {
                try await sftpService?.listDirectory(t)
            } catch {
                withAnimation { toast = "No such file or directory: \(t)" }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { toast = nil }
            }
        }
    }

    // MARK: - File List — native List with system multi-select (Shift/Cmd) + double-click

    // swiftlint:disable:next function_body_length
    private func fileList(_ service: SFTPService) -> some View {
        List(service.entries, id: \.id, selection: $selection) { entry in
            SFTPFileRow(entry: entry)
                .tag(entry.id)
                .onTapGesture(count: 2) {
                    if entry.isDirectory {
                        Task {
                            do { try await service.enterDirectory(entry) } catch {
                                service.errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
                .contextMenu {
                    if entry.isDirectory {
                        Button {
                            Task {
                                do { try await service.enterDirectory(entry) } catch {
                                    service.errorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            Label(i18n.t(.open), systemImage: "folder")
                        }
                    }
                    Button {
                        #if os(macOS)
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = entry.name
                            panel.isExtensionHidden = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                Task {
                                    do {
                                        try await service.download(entry, to: url)
                                        onDownloadCompleted?()
                                    } catch {
                                        service.errorMessage = error.localizedDescription
                                    }
                                }
                            }
                        #endif
                    } label: {
                        Label(i18n.t(.download), systemImage: "arrow.down.circle")
                    }
                    Divider()
                    Button {
                        if selection.contains(entry.id) && selection.count > 1 {
                            pendingDeleteIDs = selection
                        } else {
                            pendingDeleteEntry = entry
                        }
                    } label: {
                        Label(i18n.t(.delete), systemImage: "trash")
                    }
                }
        }
        .listStyle(.plain)
        .animation(nil, value: service.entries.count)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        if let onUpload {
                            onUpload(url)
                        } else {
                            do {
                                for try await _ in service.upload(url) {}
                            } catch {
                                service.errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
            return true
        }
    }

    // MARK: - Actions

    private func connectSFTP() async {
        guard let session = tab.session, session.sshService != nil else {
            Log.sftp.warning("Cannot connect SFTP: no SSH service for tab \(tab.title)")
            return
        }
        Log.sftp.info("Connecting SFTP for tab \(tab.title)...")
        if await session.ensureSFTP() != nil {
            Log.sftp.info("SFTP connected for tab \(tab.title)")
        } else {
            let message = session.sftpErrorMessage ?? "unknown error"
            Log.sftp.error("SFTP connection failed for tab \(tab.title): \(message)")
        }
    }
}
