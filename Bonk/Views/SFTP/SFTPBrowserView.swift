//
//  SFTPBrowserView.swift
//  Bonk
//

import SwiftUI
import UniformTypeIdentifiers
import os.log

/// SFTP file browser panel.
struct SFTPBrowserView: View {
    @EnvironmentObject var i18n: I18n
    let tab: TerminalTab
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDeleteEntry: SFTPFileEntry?

    private var sftpService: SFTPService? { tab.sftpService }
    private var isConnected: Bool { sftpService != nil }

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
                                do { try await service.listDirectory() }
                                catch { service.errorMessage = error.localizedDescription }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    fileList(service)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 40))
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

            // Transfer progress
            if let service = sftpService, !service.transfers.isEmpty {
                Divider()
                transferPanel(service)
            }
        }
        .frame(minWidth: 240)
        .alert(i18n.t(.newFolder), isPresented: $showNewFolder) {
            TextField(i18n.t(.newFolder), text: $newFolderName)
            Button(i18n.t(.create)) {
                guard !newFolderName.isEmpty, let service = sftpService else { return }
                Task {
                    do { try await service.createDirectory(name: newFolderName) }
                    catch { service.errorMessage = error.localizedDescription }
                }
                newFolderName = ""
            }
            Button(i18n.t(.cancel), role: .cancel) { newFolderName = "" }
        }
        .task(id: tab.id) {
            try? await Task.sleep(for: .milliseconds(200))
            if tab.connectionState.isConnected && tab.sftpService == nil {
                await connectSFTP()
            }
        }
        .alert(i18n.t(.delete), isPresented: deleteEntryAlertBinding) {
            Button(i18n.t(.delete), role: .destructive) {
                if let entry = pendingDeleteEntry, let service = sftpService {
                    Task {
                        do { try await service.delete(entry) }
                        catch { service.errorMessage = error.localizedDescription }
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
    }

    private var deleteEntryAlertBinding: Binding<Bool> {
        Binding(get: { pendingDeleteEntry != nil }, set: { if !$0 { pendingDeleteEntry = nil } })
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
                            Task {
                                do { try await sftpService?.upload(url) }
                                catch { sftpService?.errorMessage = error.localizedDescription }
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
                        do { try await sftpService?.listDirectory() }
                        catch { sftpService?.errorMessage = error.localizedDescription }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(i18n.t(.refresh))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Path Bar

    private var pathBar: some View {
        HStack(spacing: 4) {
            Button {
                Task {
                    do { try await sftpService?.goUp() }
                    catch { sftpService?.errorMessage = error.localizedDescription }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(sftpService?.currentPath == "/")

            Text(sftpService?.currentPath ?? "/")
                .font(.system(size: 11).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }

    // MARK: - File List

    private func fileList(_ service: SFTPService) -> some View {
        List(service.entries) { entry in
            SFTPFileRow(entry: entry)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if entry.isDirectory {
                        Task {
                            do { try await service.enterDirectory(entry) }
                            catch { service.errorMessage = error.localizedDescription }
                        }
                    }
                }
                .contextMenu {
                    if entry.isDirectory {
                        Button {
                            Task {
                            do { try await service.enterDirectory(entry) }
                            catch { service.errorMessage = error.localizedDescription }
                        }
                        } label: {
                            Label(i18n.t(.open), systemImage: "folder")
                        }
                    }

                    Button {
                        #if os(macOS)
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = entry.name
                        if panel.runModal() == .OK, let url = panel.url {
                            Task {
                                do { try await service.download(entry, to: url) }
                                catch { service.errorMessage = error.localizedDescription }
                            }
                        }
                        #endif
                    } label: {
                        Label(i18n.t(.download), systemImage: "arrow.down.circle")
                    }

                    Divider()

                    Button {
                        pendingDeleteEntry = entry
                    } label: {
                        Label(i18n.t(.delete), systemImage: "trash")
                    }
                }
        }
        .listStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        do { try await service.upload(url) }
                        catch { service.errorMessage = error.localizedDescription }
                    }
                }
            }
            return true
        }
    }

    // MARK: - Transfer Panel

    private func transferPanel(_ service: SFTPService) -> some View {
        let activeTransfers = service.transfers.filter { !$0.isComplete }
        let completedTransfers = service.transfers.filter { $0.isComplete }

        return VStack(alignment: .leading, spacing: 4) {
            if !activeTransfers.isEmpty {
                Text(i18n.t(.transfers))
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            ForEach(activeTransfers) { transfer in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(transfer.filename)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        ProgressView(value: transfer.progress)
                            .frame(height: 3)
                    }

                    Spacer()

                    if let error = transfer.error {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }

            // Show completed briefly then auto-remove
            ForEach(completedTransfers) { transfer in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Text("\(transfer.filename) done")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }
        }
        .padding(.bottom, 6)
        .task {
            // Auto-remove completed transfers after 3 seconds
            try? await Task.sleep(for: .seconds(3))
            service.transfers.removeAll { $0.isComplete }
        }
    }

    // MARK: - Actions

    private func connectSFTP() async {
        guard let sshService = await tab.sshService else {
            Log.sftp.warning("Cannot connect SFTP: no SSH service for tab \(tab.title)")
            return
        }
        Log.sftp.info("Connecting SFTP for tab \(tab.title)...")
        let sftp = SFTPService()
        do {
            try await sftp.connect(using: sshService)
            try await sftp.listDirectory()
            tab.sftpService = sftp
            Log.sftp.info("SFTP connected for tab \(tab.title)")
        } catch {
            Log.sftp.error("SFTP connection failed for tab \(tab.title): \(error.localizedDescription)")
            sftp.errorMessage = error.localizedDescription
            tab.sftpService = sftp
        }
    }
}
