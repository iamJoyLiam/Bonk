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

    /// Resolve the upload directory from PTY session or SFTP.
    func resolveUploadDir(tab: TerminalTab, sftp: SFTPService) async -> String {
        // Use PTY getCWD to get actual interactive shell directory
        if let ptyCWD = await tab.ptySession?.getCWD(), ptyCWD.hasPrefix("/") {
            tab.currentDirectory = ptyCWD
            return ptyCWD
        }
        // Fallback to tracked CWD
        if let cwd = tab.currentDirectory, cwd.hasPrefix("/") { return cwd }
        // Last resort: SFTP current path
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
