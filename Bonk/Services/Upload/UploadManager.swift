//
//  UploadManager.swift
//  Bonk
//
//  Manages file upload operations with AsyncStream progress.
//  Upload state is tracked per-tab (keyed by TerminalTab.id) so concurrent
//  uploads to different tabs never clobber each other's progress overlay.
//

import Foundation
import os.log

/// Upload overlay state for a single tab.
struct UploadState {
    var message: String?
    var progress: Double?
}

/// Manages file upload operations.
@Observable @MainActor
final class UploadManager {
    static let shared = UploadManager()

    /// Per-tab upload state. Views must only read the entry for their own tab.
    var states: [UUID: UploadState] = [:]

    private let logger = Logger(subsystem: "com.bonk", category: "Upload")

    private init() {}

    // MARK: - Per-tab accessors

    /// Message displayed in the drop overlay for the given tab.
    func message(for tabID: UUID) -> String? {
        states[tabID]?.message
    }

    /// Upload progress (0.0 - 1.0) for the given tab.
    func progress(for tabID: UUID) -> Double? {
        states[tabID]?.progress
    }

    func setMessage(_ message: String?, for tabID: UUID) {
        var state = states[tabID] ?? UploadState()
        state.message = message
        states[tabID] = state
    }

    private func setProgress(_ progress: Double?, for tabID: UUID) {
        var state = states[tabID] ?? UploadState()
        state.progress = progress
        states[tabID] = state
    }

    // MARK: - Public API

    /// Handle a file drop on a terminal tab.
    /// Returns true if file was uploaded directly, false if file exists (caller should show dialog).
    func handleDrop(url: URL, tab: TerminalTab, overwriteAlways: Bool, i18n: I18n) async -> Bool {
        if overwriteAlways {
            await performUpload(url, tab: tab, i18n: i18n)
            return true
        }

        guard tab.session?.sshService != nil else {
            showMessage(i18n.t(.noSSHConnection), for: tab.id, i18n: i18n)
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
            await performUpload(url, tab: tab, uploadDir: uploadDir, i18n: i18n)
            return true
        case nil:
            showMessage(i18n.t(.sftpConnectFailed), for: tab.id, i18n: i18n)
            return true
        }
    }

    /// Upload a file with AsyncStream progress.
    func performUpload(
        _ url: URL,
        tab: TerminalTab,
        uploadDir: String? = nil,
        i18n: I18n
    ) async {
        let tabID = tab.id
        guard tab.session?.sshService != nil else {
            showMessage(i18n.t(.noSSHConnection), for: tabID, i18n: i18n)
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

        // Show upload message with progress (scoped to this tab only)
        setMessage("\(filename) → \(targetDir)", for: tabID)
        setProgress(0, for: tabID)

        do {
            // Consume AsyncStream for progress updates
            let stream = sftp.upload(url, to: remotePath)
            for try await progress in stream {
                // Stale guard: another upload may have taken over this tab's slot
                guard message(for: tabID)?.hasPrefix(filename) == true else { return }
                setProgress(progress, for: tabID)
            }

            // Success
            setProgress(1.0, for: tabID)
            setMessage(i18n.tr(.uploadSuccess, args: filename, targetDir), for: tabID)
            try? await Task.sleep(for: .seconds(1))
            clear(tabID: tabID)
        } catch {
            logger.error("Upload failed: \(error.localizedDescription)")
            setProgress(nil, for: tabID)
            setMessage(i18n.tr(.uploadFailed, args: error.localizedDescription), for: tabID)
            try? await Task.sleep(for: .seconds(3))
            clear(tabID: tabID)
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
        guard let session = tab.session, session.sshService != nil else { return nil }
        if let sftp = await session.ensureSFTP() {
            return sftp
        } else {
            let message = session.sftpErrorMessage.map {
                i18n.tr(.sftpConnectFailed, args: $0)
            } ?? i18n.t(.sftpConnectFailed)
            showMessage(message, for: tab.id, i18n: i18n)
            return nil
        }
    }

    /// Show a temporary message scoped to one tab.
    private func showMessage(_ message: String, for tabID: UUID, i18n _: I18n) {
        setMessage(message, for: tabID)
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.message(for: tabID) == message {
                self.setMessage(nil, for: tabID)
            }
        }
    }

    /// Clear upload state for one tab. Other tabs are untouched.
    func clear(tabID: UUID) {
        states[tabID] = nil
    }
}
