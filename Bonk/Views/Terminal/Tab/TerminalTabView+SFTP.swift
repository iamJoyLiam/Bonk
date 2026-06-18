//
//  TerminalTabView+SFTP.swift
//  Bonk
//
//  Extracted from TerminalTabView.swift
//

import os.log
import SwiftUI

extension TerminalTabView {
    /// Ensure SFTP service is connected for the given tab.
    func ensureSFTP(for tab: TerminalTab) async -> SFTPService? {
        if let existing = tab.session?.sftpService { return existing }
        guard let sshService = tab.session?.sshService else { return nil }
        let sftp = SFTPService()
        do {
            try await sftp.connect(using: sshService)
            tab.session?.sftpService = sftp
            return sftp
        } catch {
            dropMessage = i18n.tr(.sftpConnectFailed, args: error.localizedDescription)
            try? await Task.sleep(for: .seconds(2))
            dropMessage = nil
            return nil
        }
    }

    /// Resolve the upload directory from cached CWD or SFTP.
    func resolveUploadDir(tab: TerminalTab, sftp: SFTPService) async -> String {
        // 1. Use cached CWD (updated by OSC 7 detection in background)
        if let cwd = tab.currentDirectory, cwd.hasPrefix("/") {
            return cwd
        }
        // 2. Fallback to SFTP current path
        return sftp.currentPath
    }

    /// Handle file drop: check existence, show dialog only if file already exists.
    func handleDrop(url: URL, tab: TerminalTab) async {
        if preferences.sftpOverwriteAlways ?? false {
            await performUpload(url, tab: tab, isOverwrite: true)
            return
        }
        guard tab.session?.sshService != nil else {
            dropMessage = i18n.t(.noSSHConnection)
            try? await Task.sleep(for: .seconds(2))
            dropMessage = nil
            return
        }
        guard let sftp = await ensureSFTP(for: tab) else { return }

        let uploadDir = await resolveUploadDir(tab: tab, sftp: sftp)
        let filename = url.lastPathComponent
        let remotePath = (uploadDir.hasSuffix("/") ? uploadDir : uploadDir + "/") + filename

        switch await sftp.fileExists(at: remotePath) {
        case true:
            pendingUploadURL = url
            pendingUploadTab = tab
            showOverwriteAlert = true
        case false:
            await performUpload(url, tab: tab, uploadDir: uploadDir)
        case nil:
            dropMessage = i18n.t(.sftpConnectFailed)
            try? await Task.sleep(for: .seconds(2))
            dropMessage = nil
        }
    }

    /// Upload file to the specified tab's server.
    func performUpload(_ url: URL, tab: TerminalTab, uploadDir: String? = nil, isOverwrite: Bool = false) async {
        guard tab.session?.sshService != nil else {
            dropMessage = i18n.t(.noSSHConnection)
            try? await Task.sleep(for: .seconds(2))
            dropMessage = nil
            return
        }
        guard let sftp = await ensureSFTP(for: tab) else { return }

        let targetDir: String = if let uploadDir {
            uploadDir
        } else {
            await resolveUploadDir(tab: tab, sftp: sftp)
        }
        let filename = url.lastPathComponent
        let remotePath = (targetDir.hasSuffix("/") ? targetDir : targetDir + "/") + filename
        dropMessage = isOverwrite
            ? i18n.tr(.overwritingTo, args: filename, targetDir)
            : i18n.tr(.uploadingTo, args: filename, targetDir)
        uploadProgress = 0

        // 启动进度监控
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if let transfer = sftp.transfers.last(where: { $0.filename == filename && !$0.isComplete }) {
                    uploadProgress = transfer.progress
                }
            }
        }

        do {
            try await sftp.upload(url, to: remotePath)
            progressTask.cancel()
            uploadProgress = 1.0
            dropMessage = i18n.tr(.uploadSuccess, args: filename, targetDir)
            try? await Task.sleep(for: .seconds(1))
            uploadProgress = nil
            dropMessage = nil
        } catch {
            progressTask.cancel()
            uploadProgress = nil
            Log.sftp.error("Upload failed: \(error.localizedDescription)")
            dropMessage = i18n.tr(.uploadFailed, args: error.localizedDescription)
            try? await Task.sleep(for: .seconds(3))
            dropMessage = nil
        }
    }
}
