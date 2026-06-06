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
        if let existing = tab.sftpService { return existing }
        guard let sshService = tab.sshService else { return nil }
        let sftp = SFTPService()
        do {
            try await sftp.connect(using: sshService)
            tab.sftpService = sftp
            return sftp
        } catch {
            dropMessage = i18n.tr(.sftpConnectFailed, args: error.localizedDescription)
            try? await Task.sleep(for: .seconds(2))
            dropMessage = nil
            return nil
        }
    }

    /// Resolve the upload directory from tab state or SSH query.
    func resolveUploadDir(tab: TerminalTab, sftp: SFTPService) async -> String {
        if let cwd = tab.currentDirectory, cwd.hasPrefix("/") { return cwd }
        if let ssh = tab.sshService, let execCWD = try? await ssh.executeCommand("pwd"), execCWD.hasPrefix("/") {
            tab.currentDirectory = execCWD
            return execCWD
        }
        return sftp.currentPath
    }

    /// Handle file drop: check existence, show dialog only if file already exists.
    func handleDrop(url: URL, tab: TerminalTab) async {
        if overwriteAlways {
            await performUpload(url, tab: tab)
            return
        }
        guard tab.sshService != nil else {
            dropMessage = i18n.t(.noSSHConnection)
            try? await Task.sleep(for: .seconds(2))
            dropMessage = nil
            return
        }
        guard let sftp = await ensureSFTP(for: tab) else { return }

        let uploadDir = await resolveUploadDir(tab: tab, sftp: sftp)
        let filename = url.lastPathComponent
        let remotePath = (uploadDir.hasSuffix("/") ? uploadDir : uploadDir + "/") + filename

        if await sftp.fileExists(at: remotePath) {
            pendingUploadURL = url
            pendingUploadTab = tab
            showOverwriteAlert = true
        } else {
            await performUpload(url, tab: tab, uploadDir: uploadDir)
        }
    }

    /// Upload file to the specified tab's server.
    func performUpload(_ url: URL, tab: TerminalTab, uploadDir: String? = nil) async {
        guard tab.sshService != nil else {
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
        dropMessage = i18n.tr(.uploadingTo, args: filename, targetDir)
        do {
            try await sftp.upload(url, to: remotePath)
            dropMessage = i18n.tr(.uploadSuccess, args: filename, targetDir)
            try? await Task.sleep(for: .seconds(2))
            dropMessage = nil
        } catch {
            Log.sftp.error("Upload failed: \(error.localizedDescription)")
            dropMessage = i18n.tr(.uploadFailed, args: error.localizedDescription)
            try? await Task.sleep(for: .seconds(3))
            dropMessage = nil
        }
    }
}
