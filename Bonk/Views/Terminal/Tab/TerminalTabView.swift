//
//  TerminalTabView.swift
//  Bonk
//
//  Created by Joy Liam on 2026/5/25.
//

import os.log
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Center area: tab bar + active terminal content.
struct TerminalTabView: View {
    @EnvironmentObject var i18n: I18n
    @Bindable var sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let cursorStyle: String
    let cursorBlink: Bool
    @Query private var allPreferences: [UserPreferences]
    @Query(sort: \HostItem.createdAt) var allHosts: [HostItem]
    @AppStorage("ai_enabled") var aiEnabled = false
    @State var showAIEnableAlert = false

    private var preferences: UserPreferences {
        allPreferences.first ?? UserPreferences()
    }

    @State var renamingTab: TerminalTab?
    @State private var renameText = ""
    @State var dropMessage: String?
    @State var pendingUploadURL: URL?
    @State var pendingUploadTab: TerminalTab?
    @State var showOverwriteAlert = false
    @State var overwriteAlways = false
    @State var showAIChat = false
    @State var selectedTextForAI = ""
    @State var selectionObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            mainContent
            aiFloatingBubble
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAIChat)) { _ in
            if showAIChat {
                showAIChat = false
                selectedTextForAI = ""
                focusTerminal()
            } else {
                requestSelectionAndShowAI()
            }
        }
        .renameAlert(i18n: i18n, renamingTab: $renamingTab, renameText: $renameText)
        .aiEnableAlert(i18n: i18n, isPresented: $showAIEnableAlert)
        .dropOverlay(message: $dropMessage)
        .fileDropHandler(sessionManager: sessionManager, dropMessage: $dropMessage)
        .overwriteDialog(
            i18n: i18n,
            isPresented: $showOverwriteAlert,
            pendingURL: $pendingUploadURL,
            pendingTab: $pendingUploadTab,
            overwriteAlways: $overwriteAlways,
            sessionManager: sessionManager
        )
        .onChange(of: renamingTab?.id) { _, _ in
            if let tab = renamingTab { renameText = tab.title }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            if !sessionManager.tabs.isEmpty { tabBar }
            if let activeTab = sessionManager.activeTab {
                terminalContent(for: activeTab)
            } else {
                emptyState
            }
        }
    }

    // MARK: - Terminal Content

    @ViewBuilder
    private func terminalContent(for activeTab: TerminalTab) -> some View {
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
                    } catch {}
                }
            },
            onTitleChange: { sessionManager.updateTabTitle($0, tabID: activeTab.id) },
            onReconnect: { Task { await sessionManager.reconnectTab(activeTab.id) } }
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in await handleTerminalDrop(url: url, tab: activeTab) }
                }
            }
            return true
        }
        .contextMenu { terminalContextMenu }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var terminalContextMenu: some View {
        Button { requestSelectionAndShowAI() } label: {
            Label(i18n.t(.aiAssistant), systemImage: "sparkles")
        }
        Divider()
        Button { copySelectedText() } label: {
            Label(i18n.t(.copy), systemImage: "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: .command)
        Button { pasteToTerminal() } label: {
            Label(i18n.t(.aiPaste), systemImage: "doc.on.clipboard")
        }
        .keyboardShortcut("v", modifiers: .command)
        Button { selectAllText() } label: {
            Label(i18n.t(.selectAll), systemImage: "selection.pin.in.out")
        }
        .keyboardShortcut("a", modifiers: .command)
        Divider()
        Button { clearTerminal() } label: {
            Label(i18n.t(.clearTerminalCmd), systemImage: "trash")
        }
        .keyboardShortcut("k", modifiers: .command)
    }

    // MARK: - AI Floating Bubble

    @ViewBuilder
    private var aiFloatingBubble: some View {
        if showAIChat {
            AIAssistantPanel(
                initialText: selectedTextForAI,
                onPaste: { text in
                    if let activeTab = sessionManager.activeTab {
                        let bytes = Array(text.utf8)
                        Task { try? await sessionManager.sendInput(bytes[...], to: activeTab.id) }
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

    /// Handle file drop on terminal view — upload to terminal's current directory.
    private func handleTerminalDrop(url: URL, tab: TerminalTab) async {
        guard tab.sshService != nil else {
            dropMessage = i18n.t(.noSSHConnection)
            try? await Task.sleep(for: .seconds(2))
            dropMessage = nil
            return
        }
        await performUpload(url, tab: tab)
    }
}

// MARK: - Extracted ViewModifiers

private struct RenameAlertModifier: ViewModifier {
    let i18n: I18n
    @Binding var renamingTab: TerminalTab?
    @Binding var renameText: String

    func body(content: Content) -> some View {
        content
            .alert(i18n.t(.rename), isPresented: .init(
                get: { renamingTab != nil },
                set: { if !$0 { renamingTab = nil } }
            )) {
                TextField(i18n.t(.rename), text: $renameText)
                Button(i18n.t(.rename)) {
                    if let tab = renamingTab, !renameText.isEmpty { tab.title = renameText }
                    renamingTab = nil
                }
                Button(i18n.t(.cancel), role: .cancel) { renamingTab = nil }
            } message: { Text(i18n.t(.enterNewName)) }
    }
}

private struct AIEnableAlertModifier: ViewModifier {
    let i18n: I18n
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .alert(i18n.t(.aiAssistant), isPresented: $isPresented) {
                Button(i18n.t(.goToSettings)) {
                    UserDefaults.standard.set("ai", forKey: "settings_selected_tab")
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Button(i18n.t(.cancel), role: .cancel) {}
            } message: { Text(i18n.t(.enableAIHint)) }
    }
}

private struct DropOverlayModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let msg = message {
                    Text(msg)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }
}

private struct FileDropHandlerModifier: ViewModifier {
    @Bindable var sessionManager: SessionManager
    @Binding var dropMessage: String?

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let activeTab = sessionManager.activeTab,
                      activeTab.connectionState.isConnected else { return false }
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                        guard let data = data as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        Task { @MainActor in
                            // Drop handling delegated to terminal content's own handler
                        }
                    }
                }
                return true
            }
    }
}

private struct OverwriteDialogModifier: ViewModifier {
    let i18n: I18n
    @Binding var isPresented: Bool
    @Binding var pendingURL: URL?
    @Binding var pendingTab: TerminalTab?
    @Binding var overwriteAlways: Bool
    @Bindable var sessionManager: SessionManager

    func body(content: Content) -> some View {
        content
            .confirmationDialog(i18n.t(.fileExists), isPresented: $isPresented) {
                Button(i18n.t(.overwrite)) {
                    guard let url = pendingURL, let tab = pendingTab else { return }
                    pendingURL = nil; pendingTab = nil
                    Task { await performUpload(url, tab: tab) }
                }
                Button(i18n.t(.alwaysOverwrite)) {
                    guard let url = pendingURL, let tab = pendingTab else { return }
                    overwriteAlways = true; pendingURL = nil; pendingTab = nil
                    Task { await performUpload(url, tab: tab) }
                }
                Button(i18n.t(.cancel), role: .cancel) {
                    pendingURL = nil; pendingTab = nil
                }
            } message: {
                if let url = pendingURL {
                    Text(i18n.t(.fileExists).replacingOccurrences(of: "%@", with: url.lastPathComponent))
                }
            }
    }

    private func performUpload(_ url: URL, tab: TerminalTab) async {
        // Implementation in TerminalTabView+SFTP
    }
}

// MARK: - View Extension for Convenience

extension View {
    func renameAlert(i18n: I18n, renamingTab: Binding<TerminalTab?>, renameText: Binding<String>) -> some View {
        modifier(RenameAlertModifier(i18n: i18n, renamingTab: renamingTab, renameText: renameText))
    }

    func aiEnableAlert(i18n: I18n, isPresented: Binding<Bool>) -> some View {
        modifier(AIEnableAlertModifier(i18n: i18n, isPresented: isPresented))
    }

    func dropOverlay(message: Binding<String?>) -> some View {
        modifier(DropOverlayModifier(message: message))
    }

    func fileDropHandler(sessionManager: SessionManager, dropMessage: Binding<String?>) -> some View {
        modifier(FileDropHandlerModifier(sessionManager: sessionManager, dropMessage: dropMessage))
    }

    func overwriteDialog(
        i18n: I18n,
        isPresented: Binding<Bool>,
        pendingURL: Binding<URL?>,
        pendingTab: Binding<TerminalTab?>,
        overwriteAlways: Binding<Bool>,
        sessionManager: SessionManager
    ) -> some View {
        modifier(OverwriteDialogModifier(
            i18n: i18n, isPresented: isPresented,
            pendingURL: pendingURL, pendingTab: pendingTab,
            overwriteAlways: overwriteAlways, sessionManager: sessionManager
        ))
    }
}
