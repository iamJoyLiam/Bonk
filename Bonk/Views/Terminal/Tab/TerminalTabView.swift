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
import SwiftTerm

/// Center area: tab bar + active terminal content.
struct TerminalTabView: View {
    @Environment(I18n.self) var i18n
    @Bindable var sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let cursorStyle: String
    let cursorBlink: Bool
    @Query private var allPreferences: [UserPreferences]
    @Query(sort: \HostItem.createdAt) var allHosts: [HostItem]
    @AppStorage("ai_enabled") var aiEnabled = false
    @State var showAIEnableAlert = false
    @Binding var showSearch: Bool
    @State private var searchText = ""
    @State private var matchCount = 0
    @State private var currentMatch = 0
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchOverlay: SearchHighlightOverlay?

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

            if showSearch {
                VStack {
                    TerminalSearchBar(
                        searchText: $searchText,
                        isPresented: $showSearch,
                        matchCount: matchCount,
                        currentMatch: currentMatch,
                        onNext: { performSearch(.forward) },
                        onPrevious: { performSearch(.backward) }
                    )
                    .padding(.top, 8)
                    .padding(.trailing, 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            if newValue.isEmpty {
                matchCount = 0
                currentMatch = 0
                searchOverlay?.clearHighlights()
                return
            }
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await performSearchInBackground(newValue)
            }
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
                    sessionManager.sendTextToActiveTab(text)
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

    private enum SearchDirection { case forward, backward }

    private func performSearch(_ direction: SearchDirection) {
        guard !searchText.isEmpty,
              let cached = TerminalViewCache.shared.retrieve(sessionManager.activeTab?.id ?? UUID()),
              let terminal = cached.view.terminal else { return }

        // 确保覆盖层已创建
        ensureOverlayExists(for: cached.view)

        // 使用 SwiftTerm 的 findNext/findPrevious 来更新当前匹配
        let found: Bool
        switch direction {
        case .forward:
            found = cached.view.findNext(searchText)
            if found { currentMatch = currentMatch >= matchCount ? 1 : currentMatch + 1 }
        case .backward:
            found = cached.view.findPrevious(searchText)
            if found { currentMatch = currentMatch <= 1 ? matchCount : currentMatch - 1 }
        }

        if found {
            // 更新覆盖层的当前匹配索引
            updateOverlayCurrentMatch()
        }
    }

    /// Perform search in background thread to avoid blocking UI
    private func performSearchInBackground(_ term: String) async {
        guard let tab = sessionManager.activeTab,
              let cached = TerminalViewCache.shared.retrieve(tab.id),
              let terminal = cached.view.terminal else {
            matchCount = 0
            searchOverlay?.clearHighlights()
            return
        }

        let cols = terminal.cols
        let rows = terminal.rows
        let yDisp = terminal.buffer.yDisp
        let lowerTerm = term.lowercased()
        let searchText = term

        // Perform search - using main actor since terminal.getText is not sendable
        var localMatches: [SearchHighlightOverlay.MatchResult] = []
        var totalCount = 0

        for visibleRow in 0..<rows {
            let absoluteRow = yDisp + visibleRow
            let start = Position(col: 0, row: absoluteRow)
            let end = Position(col: cols - 1, row: absoluteRow)
            let lineText = terminal.getText(start: start, end: end).lowercased()

            var searchStart = lineText.startIndex
            while searchStart < lineText.endIndex,
                  let range = lineText[searchStart...].range(of: searchText) {
                // Calculate column width accounting for CJK characters
                let preText = String(lineText[lineText.startIndex..<range.lowerBound])
                let colIndex = calculateTerminalColumns(for: preText)

                let matchText = String(lineText[range.lowerBound..<range.upperBound])
                let matchLength = calculateTerminalColumns(for: matchText)

                if colIndex < cols {
                    localMatches.append(SearchHighlightOverlay.MatchResult(
                        row: visibleRow,
                        col: colIndex,
                        length: min(matchLength, cols - colIndex)
                    ))
                }
                totalCount += 1
                searchStart = range.upperBound
            }
        }

        // Update UI
        self.matchCount = totalCount
        self.currentMatch = 0

        // 确保覆盖层已创建
        self.ensureOverlayExists(for: cached.view)

        self.searchOverlay?.updateMatches(localMatches, currentMatchIndex: -1)
    }

    /// Ensure overlay exists for a terminal view
    private func ensureOverlayExists(for terminalView: TerminalView) {
        if searchOverlay == nil {
            let overlay = SearchHighlightOverlay(terminalView: terminalView)
            terminalView.addSubview(overlay)
            searchOverlay = overlay
        }
    }

    /// Update current match index in overlay
    private func updateOverlayCurrentMatch() {
        searchOverlay?.updateCurrentMatchIndex(currentMatch - 1)
    }

    /// Handle file drop on terminal view — upload to terminal's current directory.
    private func handleTerminalDrop(url: URL, tab: TerminalTab) async {
        guard tab.session?.sshService != nil else {
            dropMessage = i18n.t(.noSSHConnection)
            try? await Task.sleep(for: .seconds(2))
            dropMessage = nil
            return
        }
        await performUpload(url, tab: tab)
    }
}
