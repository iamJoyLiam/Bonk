//
//  SFTPWindowView.swift
//  Bonk
//
//  SFTP file browser as an independent macOS window.
//  Opens when clicking the SFTP button in the right sidebar.
//

import SwiftUI

struct SFTPWindowView: View {
    @EnvironmentObject var i18n: I18n
    @Bindable var sessionManager: SessionManager

    var body: some View {
        Group {
            if let tab = sessionManager.activeTab {
                SFTPBrowserView(tab: tab)
            } else {
                ContentUnavailableView(
                    i18n.t(.noActiveSession),
                    systemImage: "folder.badge.questionmark",
                    description: Text(i18n.t(.connectToHostFirst))
                )
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            // Auto-connect SFTP when window opens
            if let tab = sessionManager.activeTab, tab.sftpService == nil {
                Task {
                    _ = await ensureSFTP(for: tab)
                }
            }
        }
    }

    private func ensureSFTP(for tab: TerminalTab) async -> SFTPService? {
        if let existing = tab.sftpService { return existing }
        guard let sshService = tab.sshService else { return nil }
        let sftp = SFTPService()
        do {
            try await sftp.connect(using: sshService)
            tab.sftpService = sftp
            return sftp
        } catch {
            return nil
        }
    }
}
