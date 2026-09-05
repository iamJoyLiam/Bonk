//
//  TerminalTabView.swift
//  Bonk
//
//  Terminal tab view with split pane support.
//

import os.log
import SwiftData
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// Center area: tab bar + active terminal content.
struct TerminalTabView: View {
    @Environment(I18n.self) var i18n
    @Bindable var sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let cursorStyle: String
    let cursorBlink: Bool
    @Query private var allPreferences: [UserPreferences]
    @AppStorage("ai_enabled") var aiEnabled = false
    @State var showAIEnableAlert = false
    @Binding var showSearch: Bool
    @State private var searchText = ""
    @State private var matchCount = 0
    @State private var currentMatch = 0
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var lastAIToggle = Date.distantPast

    var preferences: UserPreferences {
        allPreferences.first ?? UserPreferences()
    }

    let uploadManager = UploadManager.shared
    @State var renamingTab: TerminalTab?
    @State private var renameText = ""
    @State var pendingUploadURL: URL?
    @State var pendingUploadTab: TerminalTab?
    @State var showOverwriteAlert = false
    @State var showAIChat = false
    @State var selectedTextForAI = ""
    @State var selectionObserver: NSObjectProtocol?
    @State var showQuickConnect = false
    @State private var copyMessage: String?
    @State var isHoverPlus = false
    @Namespace var tabNamespace

    var body: some View {
        mainView
            .onChange(of: searchText) { _, newValue in
                handleSearchTextChange(newValue)
            }
            .onChange(of: showSearch) { _, isShowing in
                TerminalSearchState.isActive = isShowing
                if !isShowing {
                    if let tab = sessionManager.activeTab,
                       let paneID = tab.activePaneID,
                       let cached = TerminalViewCache.shared.retrieve(paneID) {
                        cached.view.clearSearch()
                    }
                    searchText = ""
                    matchCount = 0
                    currentMatch = 0
                    focusTerminal()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAIChat)) { _ in
                toggleAIChat()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleTerminalSearch)) { _ in
                showSearch = !showSearch
            }
            .onReceive(NotificationCenter.default.publisher(for: .aiAgentCommandExecuted)) { note in
                handleAgentMirror(note)
            }
            .terminalShortcuts(sessionManager)
            .renameAlert(i18n: i18n, renamingTab: $renamingTab, renameText: $renameText)
            .aiEnableAlert(i18n: i18n, isPresented: $showAIEnableAlert)
            .dropOverlay(message: uploadManagerBinding, uploadProgress: uploadManager.uploadProgress)
            .copyOverlay(message: $copyMessage)
            .overwriteDialog(
                i18n: i18n,
                isPresented: $showOverwriteAlert,
                pendingURL: $pendingUploadURL,
                pendingTab: $pendingUploadTab,
                overwriteAlways: overwriteAlwaysBinding,
                sessionManager: sessionManager
            ) { url, tab in
                Task { await uploadManager.performUpload(url, tab: tab, i18n: i18n) }
            }
            .onChange(of: renamingTab?.id) { _, _ in
                if let tab = renamingTab { renameText = tab.title }
            }
            .paneNavigation(navigatePane)
            .onReceive(NotificationCenter.default.publisher(for: .requestTerminalSelection)) { _ in
                copySelection()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCopyMessage)) { _ in
                withAnimation { copyMessage = i18n.t(.copied) }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { copyMessage = nil }
                }
            }
            .onDisappear {
                TerminalSearchState.isActive = false
            }
            .sheet(item: $sessionManager.authRetryRequest) { request in
                AuthRetrySheet(host: request.host, rawError: request.rawError, lastAttemptPassword: request.lastAttemptPassword, onRetry: { host in sessionManager.completeAuthRetry(with: host) }, onCancel: { sessionManager.cancelAuthRetry() }, onEditFull: { sessionManager.hostToEdit = request.host; sessionManager.cancelAuthRetry() })
                    .environment(sessionManager.modelContext.map { _ in I18n.shared } ?? I18n.shared)
            }
            .sheet(item: $sessionManager.hostToEdit) { host in
                AddHostSheet(existingHost: host) { _ in sessionManager.hostToEdit = nil }
            }
    }

    private var mainView: some View {
        ZStack {
            mainContent
            aiFloatingBubble
            if showSearch { searchBar }
        }
    }

    private var searchBar: some View {
        VStack {
            TerminalSearchBar(
                searchText: $searchText,
                isPresented: $showSearch,
                matchCount: matchCount,
                currentMatch: currentMatch,
                onNext: { performSearch(.forward) },
                onPrevious: { performSearch(.backward) }
            )
            .padding(.top, AppStyle.spacingM)
            .padding(.trailing, AppStyle.spacingXL)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func navigatePane(_ direction: NavigationDirection) {
        guard let tab = sessionManager.activeTab else { return }
        FocusManager.shared.navigate(direction: direction, in: tab)
        tab.activePaneID = FocusManager.shared.focusedPaneID
    }

    private func handleSearchTextChange(_ newValue: String) {
        searchDebounceTask?.cancel()
        if newValue.isEmpty {
            matchCount = 0
            currentMatch = 0
            if let tab = sessionManager.activeTab,
               let paneID = tab.activePaneID,
               let cached = TerminalViewCache.shared.retrieve(paneID) {
                cached.view.clearSearch()
            }
            return
        }
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            updateMatchCount(newValue)
        }
    }

    /// Mirror AI agent command executions into the active terminal view.
    private func handleAgentMirror(_ notification: Notification) {
        guard let tab = sessionManager.activeTab,
              let paneID = tab.activePaneID,
              let cached = TerminalViewCache.shared.retrieve(paneID),
              let command = notification.userInfo?[AITerminalMirror.commandKey] as? String,
              let raw = notification.userInfo?[AITerminalMirror.statusKey] as? String,
              let status = AgentMessage.CommandStatus(rawValue: raw)
        else { return }

        let duration = notification.userInfo?[AITerminalMirror.durationKey] as? Double
        let output = notification.userInfo?[AITerminalMirror.outputKey] as? String
        let host = notification.userInfo?[AITerminalMirror.hostKey] as? String
        let text = AITerminalMirror.format(
            command: command, status: status,
            duration: duration, output: output, hostName: host
        )
        cached.view.feed(text: text)

        if status == .success || status == .failed {
            Task { @MainActor in
                cached.view.window?.makeFirstResponder(cached.view)
            }
        }
    }

    private func toggleAIChat() {
        let now = Date()
        guard now.timeIntervalSince(lastAIToggle) > 0.2 else { return }
        lastAIToggle = now
        if showAIChat {
            showAIChat = false
            selectedTextForAI = ""
            focusTerminal()
        } else {
            requestSelectionAndShowAI()
        }
    }

    private func handleFileDrop(url: URL, tab: TerminalTab) {
        Task {
            let overwriteAlways = preferences.sftpOverwriteAlways ?? false
            let uploaded = await uploadManager.handleDrop(
                url: url, tab: tab, overwriteAlways: overwriteAlways, i18n: i18n
            )
            if !uploaded {
                pendingUploadURL = url
                pendingUploadTab = tab
                showOverwriteAlert = true
            }
        }
    }

    private var uploadManagerBinding: Binding<String?> {
        Binding(get: { uploadManager.dropMessage }, set: { uploadManager.dropMessage = $0 })
    }

    private var overwriteAlwaysBinding: Binding<Bool> {
        Binding(get: { preferences.sftpOverwriteAlways ?? false }, set: { preferences.sftpOverwriteAlways = $0 })
    }
}

// MARK: - Optional Bool Binding Helper

extension Binding where Value == Bool? {
    var orFalse: Binding<Bool> {
        Binding<Bool>(get: { self.wrappedValue ?? false }, set: { self.wrappedValue = $0 })
    }
}

extension TerminalTabView {
    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            if !sessionManager.tabs.isEmpty { tabBar }
            if let activeTab = sessionManager.activeTab {
                TabLayoutView(
                    tab: activeTab, sessionManager: sessionManager,
                    colorScheme: colorScheme, preferences: preferences,
                    cursorStyle: cursorStyle, cursorBlink: cursorBlink
                )
            } else {
                emptyState
            }
        }
    }

    // MARK: - AI Floating Bubble

    @ViewBuilder
    private var aiFloatingBubble: some View {
        if showAIChat {
            TerminalAIPanel(
                initialText: selectedTextForAI,
                terminalContext: TerminalContext(tab: sessionManager.activeTab),
                onPaste: { text in
                    pasteOnly(text)
                    showAIChat = false; selectedTextForAI = ""
                },
                onRun: { text in
                    sessionManager.sendTextToActiveTab(text)
                    showAIChat = false; selectedTextForAI = ""
                },
                onDismiss: {
                    showAIChat = false; selectedTextForAI = ""
                    focusTerminal()
                }
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, AppStyle.spacingXL)
            .zIndex(1)
        }
    }

    /// Paste text without sending Enter.
    private func pasteOnly(_ text: String) {
        guard let tab = sessionManager.activeTab,
              let paneID = tab.activePaneID else { return }
        let bytes = ArraySlice(text.utf8)
        Task {
            try? await sessionManager.sendInput(bytes, to: tab.id, paneID: paneID)
        }
    }

    // MARK: - Search

    private enum SearchDirection { case forward, backward }

    private func performSearch(_ direction: SearchDirection) {
        guard !searchText.isEmpty,
              let tab = sessionManager.activeTab,
              let paneID = tab.activePaneID,
              let cached = TerminalViewCache.shared.retrieve(paneID) else { return }

        let found: Bool
        switch direction {
        case .forward:
            found = cached.view.findNext(searchText)
            if found { currentMatch = currentMatch >= matchCount ? 1 : currentMatch + 1 }
        case .backward:
            found = cached.view.findPrevious(searchText)
            if found { currentMatch = currentMatch <= 1 ? matchCount : currentMatch - 1 }
        }
    }

    private func updateMatchCount(_ term: String) {
        guard let tab = sessionManager.activeTab,
              let paneID = tab.activePaneID,
              let cached = TerminalViewCache.shared.retrieve(paneID) else {
            matchCount = 0; return
        }
        let summary = cached.view.searchMatchSummary(term)
        matchCount = summary.total
        currentMatch = summary.index
    }

    func copySelection() {
        guard let activeTab = sessionManager.activeTab,
              let cached = TerminalViewCache.shared.retrieve(activeTab.id) else { return }
        if let selectedText = cached.view.getSelection(), !selectedText.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedText, forType: .string)
            withAnimation { copyMessage = i18n.t(.copied) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                withAnimation { copyMessage = nil }
            }
        }
    }
}
