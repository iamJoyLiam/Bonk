//
//  TerminalTabView.swift
//  GhostShell
//
//  Created by Joy Liam on 2026/5/25.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os.log

/// Center area: tab bar + active terminal content.
struct TerminalTabView: View {
    @EnvironmentObject var i18n: I18n
    @Bindable var sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let cursorStyle: String
    let cursorBlink: Bool
    @Query private var preferencesList: [UserPreferences]
    @Query(sort: \HostItem.createdAt) private var allHosts: [HostItem]

    private var preferences: UserPreferences {
        preferencesList.first ?? UserPreferences()
    }
    @State private var renamingTab: TerminalTab?
    @State private var renameText = ""
    @State private var dropMessage: String?
    @State private var pendingUploadURL: URL?
    @State private var pendingUploadTab: TerminalTab?
    @State private var showOverwriteAlert = false
    @State private var overwriteAlways = false
    @State private var showAIChat = false
    @State private var selectedTextForAI = ""
    @State private var selectionObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if !sessionManager.tabs.isEmpty {
                    tabBar
                }

                if let activeTab = sessionManager.activeTab {
                    TerminalContainerView(
                        activeTab: activeTab,
                        colorScheme: colorScheme,
                        fontSize: preferences.fontSize,
                        fontFamily: preferences.fontFamily,
                        lineHeight: preferences.lineHeight,
                        scrollbackLines: preferences.scrollbackLines,
                        cursorStyle: cursorStyle,
                        cursorBlink: cursorBlink,
                        copyOnSelect: preferences.copyOnSelect,
                        onSend: { data in
                            Task {
                                do {
                                    try await sessionManager.sendInput(data, to: activeTab.id)
                                } catch {
                                    sessionManager.lastError = error.localizedDescription
                                    sessionManager.showError = true
                                }
                            }
                        },
                        onResize: { cols, rows in
                            Task {
                                do {
                                    try await sessionManager.resizePTY(cols: cols, rows: rows, tabID: activeTab.id)
                                } catch {
                                    // Resize failure is non-critical, log only
                                }
                            }
                        },
                        onTitleChange: { newTitle in
                            sessionManager.updateTabTitle(newTitle, tabID: activeTab.id)
                        },
                        onReconnect: {
                            Task { await sessionManager.reconnectTab(activeTab.id) }
                        }
                    )
                    .contextMenu {
                        Button {
                            requestSelectionAndShowAI()
                        } label: {
                            Label("AI Assistant", systemImage: "sparkles")
                        }

                        Divider()

                        Button {
                            copySelectedText()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .keyboardShortcut("c", modifiers: .command)

                        Button {
                            pasteToTerminal()
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .keyboardShortcut("v", modifiers: .command)

                        Button {
                            selectAllText()
                        } label: {
                            Label("Select All", systemImage: "selection.pin.in.out")
                        }
                        .keyboardShortcut("a", modifiers: .command)

                        Divider()

                        Button {
                            clearTerminal()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .keyboardShortcut("k", modifiers: .command)
                    }
                } else {
                    emptyState
                }
            }

            // AI Floating Bubble - truly floating, non-blocking
            if showAIChat {
                AIAssistantPanel(
                    initialText: selectedTextForAI,
                    onPaste: { text in
                        if let activeTab = sessionManager.activeTab {
                            let bytes = Array(text.utf8)
                            Task {
                                try? await sessionManager.sendInput(bytes[...], to: activeTab.id)
                            }
                        }
                        showAIChat = false
                        selectedTextForAI = ""
                    },
                    onDismiss: {
                        showAIChat = false
                        selectedTextForAI = ""
                        focusTerminal()
                    }
                )
                .zIndex(1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAIChat)) { _ in
            // Toggle AI chat
            if showAIChat {
                showAIChat = false
                selectedTextForAI = ""
                focusTerminal()
            } else {
                requestSelectionAndShowAI()
            }
        }
        .alert(i18n.t(.rename), isPresented: .init(
            get: { renamingTab != nil },
            set: { if !$0 { renamingTab = nil } }
        )) {
            TextField(i18n.t(.rename), text: $renameText)
            Button(i18n.t(.rename)) {
                if let tab = renamingTab, !renameText.isEmpty {
                    tab.title = renameText
                }
                renamingTab = nil
            }
            Button(i18n.t(.cancel), role: .cancel) {
                renamingTab = nil
            }
        } message: {
            Text(i18n.t(.enterNewName))
        }
        .onChange(of: renamingTab?.id) { _, _ in
            if let tab = renamingTab {
                renameText = tab.title
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = dropMessage {
                Text(msg)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let activeTab = sessionManager.activeTab,
                  activeTab.connectionState.isConnected else { return false }
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        await handleDrop(url: url, tab: activeTab)
                    }
                }
            }
            return true
        }
        .confirmationDialog(i18n.t(.fileExists), isPresented: $showOverwriteAlert) {
            Button(i18n.t(.overwrite)) {
                guard let url = pendingUploadURL, let tab = pendingUploadTab else { return }
                pendingUploadURL = nil
                pendingUploadTab = nil
                Task { await performUpload(url, tab: tab) }
            }
            Button(i18n.t(.alwaysOverwrite)) {
                guard let url = pendingUploadURL, let tab = pendingUploadTab else { return }
                overwriteAlways = true
                pendingUploadURL = nil
                pendingUploadTab = nil
                Task { await performUpload(url, tab: tab) }
            }
            Button(i18n.t(.cancel), role: .cancel) {
                pendingUploadURL = nil
                pendingUploadTab = nil
            }
        } message: {
            if let url = pendingUploadURL {
                Text(i18n.t(.fileExists).replacingOccurrences(of: "%@", with: url.lastPathComponent))
            }
        }
    }

    /// Ensure SFTP service is connected for the given tab.
    private func ensureSFTP(for tab: TerminalTab) async -> SFTPService? {
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
    private func resolveUploadDir(tab: TerminalTab, sftp: SFTPService) async -> String {
        if let cwd = tab.currentDirectory, cwd.hasPrefix("/") { return cwd }
        if let ssh = tab.sshService, let execCWD = try? await ssh.executeCommand("pwd"), execCWD.hasPrefix("/") {
            tab.currentDirectory = execCWD
            return execCWD
        }
        return sftp.currentPath
    }

    /// Handle file drop: check existence, show dialog only if file already exists.
    private func handleDrop(url: URL, tab: TerminalTab) async {
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
    private func performUpload(_ url: URL, tab: TerminalTab, uploadDir: String? = nil) async {
        guard tab.sshService != nil else {
            dropMessage = i18n.t(.noSSHConnection)
            try? await Task.sleep(for: .seconds(2))
            dropMessage = nil
            return
        }
        guard let sftp = await ensureSFTP(for: tab) else { return }

        let targetDir: String
        if let uploadDir {
            targetDir = uploadDir
        } else {
            targetDir = await resolveUploadDir(tab: tab, sftp: sftp)
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

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessionManager.tabs) { tab in
                    tabButton(tab)
                        .contextMenu {
                            Button {
                                // Duplicate: create new connection to same host
                                let host = tab.hostItem
                                sessionManager.openTab(for: host)
                            } label: {
                                Label(i18n.t(.duplicate), systemImage: "plus.square.on.square")
                            }

                            Divider()

                            // Color label submenu
                            Menu {
                                Button {
                                    tab.colorLabel = nil
                                } label: {
                                    Text("None")
                                }

                                ForEach(TerminalTab.colorLabels, id: \.name) { label in
                                    Button {
                                        tab.colorLabel = label.name
                                    } label: {
                                        HStack {
                                            Circle()
                                                .fill(label.color)
                                                .frame(width: 10, height: 10)
                                            Text(label.name.capitalized)
                                            if tab.colorLabel == label.name {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("Color", systemImage: "paintpalette")
                            }

                            Divider()

                            Button {
                                renamingTab = tab
                            } label: {
                                Label(i18n.t(.rename), systemImage: "pencil")
                            }

                            Divider()

                            Button(role: .destructive) {
                                Task { await sessionManager.closeTab(tab.id) }
                            } label: {
                                Label(i18n.t(.close), systemImage: "xmark")
                            }
                        }
                }

                // "+" button — click to add host, long-press for menu
                Menu {
                    ForEach(allHosts) { host in
                        let isOpen = sessionManager.tabs.contains(where: { $0.hostItem.id == host.id })
                        Button {
                            if isOpen {
                                if let tab = sessionManager.tabs.first(where: { $0.hostItem.id == host.id }) {
                                    sessionManager.selectTab(tab.id)
                                }
                            } else {
                                sessionManager.openTab(for: host)
                            }
                        } label: {
                            Label(host.name, systemImage: isOpen ? "checkmark" : "plus")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.quaternary.opacity(0.3))
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 40)
        .background {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .bottom) {
                    Divider()
                }
        }
    }

    private func tabButton(_ tab: TerminalTab) -> some View {
        let isActive = sessionManager.activeTabID == tab.id
        return Button {
            sessionManager.selectTab(tab.id)
        } label: {
            HStack(spacing: 6) {
                // Connection status indicator
                Circle()
                    .fill(tabColor(tab.connectionState))
                    .frame(width: 5, height: 5)

                Text(tab.title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)

                // Close button - visible on active tab
                if isActive {
                    Button {
                        Task { await sessionManager.closeTab(tab.id) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: 80, maxWidth: 160)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tabBackgroundColor(tab, isActive: isActive))
            }
            .overlay(alignment: .bottom) {
                if isActive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tabAccentColor(tab))
                        .frame(height: 2)
                        .offset(y: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Determine tab background color based on color label and active state.
    private func tabBackgroundColor(_ tab: TerminalTab, isActive: Bool) -> Color {
        if let color = tab.resolvedColor {
            // Use color label as background with appropriate opacity
            return isActive ? color.opacity(0.25) : color.opacity(0.15)
        }
        // Default: accent color for active, clear for inactive
        return isActive ? Color.accentColor.opacity(0.12) : Color.clear
    }

    /// Determine tab accent color (bottom border) based on color label.
    private func tabAccentColor(_ tab: TerminalTab) -> Color {
        if let color = tab.resolvedColor {
            return color.opacity(0.7)
        }
        return Color.accentColor.opacity(0.5)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.quaternary)

            Text(i18n.t(.noTerminal))
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(i18n.t(.selectHost))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func tabColor(_ state: SSHConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .disconnected: .red
        }
    }

    /// Copy selected text from terminal.
    private func copySelectedText() {
        NotificationCenter.default.post(name: .requestTerminalSelection, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let selectedText = NSPasteboard.general.string(forType: .string), !selectedText.isEmpty {
                // Text already copied by SwiftTerm's clipboard handler
            }
        }
    }

    /// Paste text to terminal.
    private func pasteToTerminal() {
        if let text = NSPasteboard.general.string(forType: .string) {
            let bytes = Array(text.utf8)
            if let activeTab = sessionManager.activeTab {
                Task {
                    try? await sessionManager.sendInput(bytes[...], to: activeTab.id)
                }
            }
        }
    }

    /// Select all text in terminal.
    private func selectAllText() {
        NotificationCenter.default.post(name: .selectAllInTerminal, object: nil)
    }

    /// Clear terminal screen.
    private func clearTerminal() {
        let clearBytes: [UInt8] = [12] // Form feed = clear screen
        if let activeTab = sessionManager.activeTab {
            Task {
                try? await sessionManager.sendInput(clearBytes[...], to: activeTab.id)
            }
        }
    }

    /// Focus the terminal view.
    private func focusTerminal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .focusTerminal, object: nil)
        }
    }

    /// Request selected text from terminal and show AI panel.
    private func requestSelectionAndShowAI() {
        // Listen for selection response
        selectionObserver = NotificationCenter.default.addObserver(
            forName: .terminalSelectionResponse,
            object: nil,
            queue: .main
        ) { notification in
            if let selectedText = notification.object as? String, !selectedText.isEmpty {
                selectedTextForAI = selectedText
            } else {
                selectedTextForAI = ""
            }
            showAIChat = true
            // Remove observer after receiving response
            if let observer = selectionObserver {
                NotificationCenter.default.removeObserver(observer)
                selectionObserver = nil
            }
        }

        // Request selection from terminal
        NotificationCenter.default.post(name: .requestTerminalSelection, object: nil)

        // Fallback: if no response in 0.5 seconds, show AI chat
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if selectionObserver != nil {
                if let observer = selectionObserver {
                    NotificationCenter.default.removeObserver(observer)
                    selectionObserver = nil
                }
                selectedTextForAI = ""
                showAIChat = true
            }
        }
    }
}
