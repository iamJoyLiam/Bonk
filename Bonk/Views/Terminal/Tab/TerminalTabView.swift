//
//  TerminalTabView.swift
//  Bonk
//
//  Terminal tab view with split pane support.
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
    @State private var isTabBarDragOver = false
    @State private var dropPosition: DropPosition = .right

    var body: some View {
        mainView
            .onChange(of: searchText) { _, newValue in
                handleSearchTextChange(newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAIChat)) { _ in
                toggleAIChat()
            }
            .renameAlert(i18n: i18n, renamingTab: $renamingTab, renameText: $renameText)
            .aiEnableAlert(i18n: i18n, isPresented: $showAIEnableAlert)
            .dropOverlay(message: uploadManagerBinding, uploadProgress: uploadManager.uploadProgress)
            .fileDropHandler(sessionManager: sessionManager, dropMessage: uploadManagerBinding) { url, tab in
                handleFileDrop(url: url, tab: tab)
            }
            .overwriteDialog(
                i18n: i18n,
                isPresented: $showOverwriteAlert,
                pendingURL: $pendingUploadURL,
                pendingTab: $pendingUploadTab,
                overwriteAlways: overwriteAlwaysBinding,
                sessionManager: sessionManager
            ) { url, tab in
                Task { await uploadManager.performUpload(url, tab: tab, isOverwrite: true, i18n: i18n) }
            }
            .onChange(of: renamingTab?.id) { _, _ in
                if let tab = renamingTab { renameText = tab.title }
            }
            .paneNavigation(navigatePane)
    }

    @ViewBuilder
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
            .padding(.top, 8)
            .padding(.trailing, 16)
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
            searchOverlay?.clearHighlights()
            return
        }
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await performSearchInBackground(newValue)
        }
    }

    private func toggleAIChat() {
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
            let uploaded = await uploadManager.handleDrop(url: url, tab: tab, overwriteAlways: preferences.sftpOverwriteAlways ?? false, i18n: i18n)
            if !uploaded {
                pendingUploadURL = url
                pendingUploadTab = tab
                showOverwriteAlert = true
            }
        }
    }

    private var uploadManagerBinding: Binding<String?> {
        Binding(
            get: { uploadManager.dropMessage },
            set: { uploadManager.dropMessage = $0 }
        )
    }

    private var overwriteAlwaysBinding: Binding<Bool> {
        Binding(
            get: { preferences.sftpOverwriteAlways ?? false },
            set: { preferences.sftpOverwriteAlways = $0 }
        )
    }
}

// MARK: - Optional Bool Binding Helper

extension Binding where Value == Bool? {
    var orFalse: Binding<Bool> {
        Binding<Bool>(
            get: { self.wrappedValue ?? false },
            set: { self.wrappedValue = $0 }
        )
    }
}

extension TerminalTabView {
    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            if !sessionManager.tabs.isEmpty { tabBar }
            // Render the active tab's layout
            if let activeTab = sessionManager.activeTab {
                ZStack {
                    TabLayoutView(
                        tab: activeTab,
                        sessionManager: sessionManager,
                        colorScheme: colorScheme,
                        preferences: preferences,
                        cursorStyle: cursorStyle,
                        cursorBlink: cursorBlink
                    )

                    // Drop indicator (full area)
                    if isTabBarDragOver {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 3)
                            .padding(4)
                            .allowsHitTesting(false)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "plus.rectangle.on.rectangle")
                                        .font(.system(size: 24))
                                    Text("Drop to split")
                                        .font(.caption)
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.15), value: isTabBarDragOver)
                    }
                }
            } else {
                emptyState
            }
        }
        // Drop target on the entire VStack
        .onDrop(of: [.utf8PlainText], isTargeted: $isTabBarDragOver) { providers, location in
            guard let provider = providers.first,
                  let activeTab = sessionManager.activeTab else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                guard let uuidString = string as? String,
                      let sourceTabID = UUID(uuidString: uuidString),
                      sourceTabID != activeTab.id else { return }
                Task { @MainActor in
                    // Calculate position from drop location
                    let pos = calculateDropPosition(from: location)
                    print("[DROP] ✅ source=\(sourceTabID), target=\(activeTab.id), pos=\(pos)")
                    sessionManager.addPaneFromTab(sourceTabID, to: activeTab.id, position: pos)
                }
            }
            return true
        }
    }

    // MARK: - Drop Region Indicator

    @ViewBuilder
    private var dropRegionIndicator: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let inset: CGFloat = 4
            let center = regionCenter(in: size)

            ZStack {
                // Region highlight
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .frame(
                        width: dropPosition.isHorizontal ? size.width / 2 - inset * 2 : nil,
                        height: dropPosition.isVertical ? size.height / 2 - inset * 2 : nil
                    )
                    .position(center)

                // Icon
                VStack(spacing: 8) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 24))
                    Text("Drop to split")
                        .font(.caption)
                }
                .foregroundStyle(Color.accentColor)
                .position(center)
            }
        }
    }

    private func regionCenter(in size: CGSize) -> CGPoint {
        switch dropPosition {
        case .left: return CGPoint(x: size.width / 4, y: size.height / 2)
        case .right: return CGPoint(x: size.width * 3 / 4, y: size.height / 2)
        case .top: return CGPoint(x: size.width / 2, y: size.height / 4)
        case .bottom: return CGPoint(x: size.width / 2, y: size.height * 3 / 4)
        }
    }

    private func calculateDropPosition(from location: CGPoint) -> DropPosition {
        // Use window size to determine region
        guard let window = NSApp.mainWindow else { return .right }
        let size = window.contentView?.bounds.size ?? CGSize(width: 800, height: 600)

        let distances: [(DropPosition, CGFloat)] = [
            (.left, location.x),
            (.right, size.width - location.x),
            (.top, location.y),
            (.bottom, size.height - location.y)
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .right
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
              let tab = sessionManager.activeTab,
              let paneID = tab.activePaneID,
              let cached = TerminalViewCache.shared.retrieve(paneID),
              let terminal = cached.view.terminal else { return }

        ensureOverlayExists(for: cached.view)

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
            updateOverlayCurrentMatch()
        }
    }

    private func performSearchInBackground(_ term: String) async {
        guard let tab = sessionManager.activeTab,
              let paneID = tab.activePaneID,
              let cached = TerminalViewCache.shared.retrieve(paneID),
              let terminal = cached.view.terminal else {
            matchCount = 0
            searchOverlay?.clearHighlights()
            return
        }

        let cols = terminal.cols
        let rows = terminal.rows
        let yDisp = terminal.buffer.yDisp
        let searchText = term

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

        self.matchCount = totalCount
        self.currentMatch = 0

        self.ensureOverlayExists(for: cached.view)

        self.searchOverlay?.updateMatches(localMatches, currentMatchIndex: -1)
    }

    private func ensureOverlayExists(for terminalView: TerminalView) {
        if searchOverlay == nil {
            let overlay = SearchHighlightOverlay(terminalView: terminalView)
            terminalView.addSubview(overlay)
            searchOverlay = overlay
        }
    }

    private func updateOverlayCurrentMatch() {
        searchOverlay?.updateCurrentMatchIndex(currentMatch - 1)
    }

    private func handleTerminalDrop(url: URL, tab: TerminalTab) async {
        await uploadManager.performUpload(url, tab: tab, i18n: i18n)
    }
}
