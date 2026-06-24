//
//  UploadManager.swift
//  Bonk
//
//  Manages file upload operations with AsyncStream progress.
//

import Foundation
import os.log

/// Manages file upload operations.
@Observable @MainActor
final class UploadManager {
    static let shared = UploadManager()

    /// Message displayed in the drop overlay.
    var dropMessage: String?

    /// Upload progress (0.0 - 1.0).
    var uploadProgress: Double?

    private let logger = Logger(subsystem: "com.bonk", category: "Upload")

    private init() {}

    // MARK: - Public API

    /// Handle a file drop on a terminal tab.
    /// Returns true if file was uploaded directly, false if file exists (caller should show dialog).
    func handleDrop(url: URL, tab: TerminalTab, overwriteAlways: Bool, i18n: I18n) async -> Bool {
        if overwriteAlways {
            await performUpload(url, tab: tab, isOverwrite: true, i18n: i18n)
            return true
        }

        guard tab.session?.sshService != nil else {
            showMessage(i18n.t(.noSSHConnection), i18n: i18n)
            return true
        }

        guard let sftp = await ensureSFTP(for: tab, i18n: i18n) else { return true }

        let uploadDir = await resolveUploadDir(tab: tab, sftp: sftp)
        let filename = url.lastPathComponent
        let remotePath = (uploadDir.hasSuffix("/") ? uploadDir : uploadDir + "/") + filename

        switch await sftp.fileExists(at: remotePath) {
        case true:
            return false // Caller should show dialog
        case false:
            await performUpload(url, tab: tab, uploadDir: uploadDir, isOverwrite: false, i18n: i18n)
            return true
        case nil:
            showMessage(i18n.t(.sftpConnectFailed), i18n: i18n)
            return true
        }
    }

    /// Upload a file with AsyncStream progress.
    func performUpload(
        _ url: URL,
        tab: TerminalTab,
        uploadDir: String? = nil,
        isOverwrite: Bool = false,
        i18n: I18n
    ) async {
        guard tab.session?.sshService != nil else {
            showMessage(i18n.t(.noSSHConnection), i18n: i18n)
            return
        }

        guard let sftp = await ensureSFTP(for: tab, i18n: i18n) else { return }

        let targetDir: String = if let uploadDir {
            uploadDir
        } else {
            await resolveUploadDir(tab: tab, sftp: sftp)
        }

        let filename = url.lastPathComponent
        let remotePath = (targetDir.hasSuffix("/") ? targetDir : targetDir + "/") + filename

        // Show message
        dropMessage = isOverwrite
            ? i18n.tr(.overwritingTo, args: filename, targetDir)
            : i18n.tr(.uploadingTo, args: filename, targetDir)
        uploadProgress = 0

        do {
            // Consume AsyncStream for progress updates
            let stream = sftp.upload(url, to: remotePath)
            for try await progress in stream {
                uploadProgress = progress
            }

            // Success
            uploadProgress = 1.0
            dropMessage = i18n.tr(.uploadSuccess, args: filename, targetDir)
            try? await Task.sleep(for: .seconds(1))
            clearState()
        } catch {
            logger.error("Upload failed: \(error.localizedDescription)")
            uploadProgress = nil
            dropMessage = i18n.tr(.uploadFailed, args: error.localizedDescription)
            try? await Task.sleep(for: .seconds(3))
            clearState()
        }
    }

    /// Resolve upload directory.
    /// Priority: OSC 7 cache → PTY getCWD → SFTP path → /
    func resolveUploadDir(tab: TerminalTab, sftp: SFTPService) async -> String {
        // 1. Cached CWD from OSC 7 detection (zero cost)
        if let cwd = tab.currentDirectory, cwd.hasPrefix("/") {
            logger.info("[UPLOAD] Using cached CWD: \(cwd)")
            return cwd
        }

        // 2. PTY getCWD — sends pwd through PTY channel (reliable, ~100ms)
        // Try up to 2 times to get a valid path
        for attempt in 1 ... 2 {
            if let ptyCWD = await tab.session?.ptySession?.getCWD(), ptyCWD.hasPrefix("/") {
                logger.info("[UPLOAD] Using PTY getCWD (attempt \(attempt)): \(ptyCWD)")
                tab.currentDirectory = ptyCWD
                return ptyCWD
            }
            // Small delay between retries
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        // 3. SFTP initial path
        let sftpPath = sftp.currentPath
        if sftpPath.hasPrefix("/") {
            logger.info("[UPLOAD] Using SFTP path: \(sftpPath)")
            return sftpPath
        }

        // 4. Safety fallback
        logger.warning("[UPLOAD] No valid path found, falling back to /")
        return "/"
    }

    // MARK: - Private

    /// Ensure SFTP service is connected for the given tab.
    func ensureSFTP(for tab: TerminalTab, i18n: I18n) async -> SFTPService? {
        if let existing = tab.session?.sftpService { return existing }
        guard let sshService = tab.session?.sshService else { return nil }

        let sftp = SFTPService()
        do {
            try await sftp.connect(using: sshService)
            tab.session?.sftpService = sftp
            return sftp
        } catch {
            showMessage(i18n.tr(.sftpConnectFailed, args: error.localizedDescription), i18n: i18n)
            return nil
        }
    }

    /// Show a temporary message.
    private func showMessage(_ message: String, i18n _: I18n) {
        dropMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if dropMessage == message {
                dropMessage = nil
            }
        }
    }

    /// Clear upload state.
    private func clearState() {
        dropMessage = nil
        uploadProgress = nil
    }
}
