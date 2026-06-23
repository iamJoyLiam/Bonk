//
//  PaneTerminalView.swift
//  Bonk
//
//  A single pane in the layout, supporting independent and linked modes.
//

import SwiftUI
import SwiftTerm

struct PaneTerminalView: View {
    @Environment(I18n.self) var i18n
    let paneState: PaneState
    let isActive: Bool
    let tab: TerminalTab
    let sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let preferences: UserPreferences
    let cursorStyle: String
    let cursorBlink: Bool

    @State private var focusManager = FocusManager.shared
    @State private var isDragOver = false
    @State private var dropPosition: DropPosition = .right
    @State private var terminalNSView: NSView?

    // Upload state
    let uploadManager = UploadManager.shared
    @State private var pendingUploadURL: URL?
    @State private var pendingUploadTab: TerminalTab?
    @State private var showOverwriteAlert = false

    var body: some View {
        VStack(spacing: 0) {
            if tab.layout.root.paneCount > 1 {
                paneTitleBar
            }

            paneContent
        }
        .opacity(isActive ? 1.0 : 0.6)
        .overlay {
            if tab.layout.root.paneCount > 1 {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
            }
        }
        .overlay {
            // Drag-and-drop overlay with indicator
            if isDragOver {
                dropIndicator
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: isDragOver)
            }
        }
        .overlay(alignment: .bottom) {
            // Upload progress overlay
            if let msg = uploadManager.dropMessage {
                VStack(spacing: 4) {
                    Text(msg)
                        .font(.caption)
                        .lineLimit(1)

                    if let progress = uploadManager.uploadProgress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 200)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            pendingUploadURL.map { i18n.tr(.fileExists, args: $0.lastPathComponent) } ?? i18n.t(.fileExists),
            isPresented: $showOverwriteAlert
        ) {
            Button(i18n.t(.overwrite)) {
                guard let url = pendingUploadURL, let tab = pendingUploadTab else { return }
                pendingUploadURL = nil; pendingUploadTab = nil
                Task { await uploadManager.performUpload(url, tab: tab, isOverwrite: true, i18n: i18n) }
            }
            Button(i18n.t(.alwaysOverwrite)) {
                guard let url = pendingUploadURL, let tab = pendingUploadTab else { return }
                pendingUploadURL = nil; pendingUploadTab = nil
                preferences.sftpOverwriteAlways = true
                Task { await uploadManager.performUpload(url, tab: tab, isOverwrite: true, i18n: i18n) }
            }
            Button(i18n.t(.cancel), role: .cancel) {
                pendingUploadURL = nil; pendingUploadTab = nil
            }
        }
        .onTapGesture {
            focusManager.focus(paneState.id)
            tab.activePaneID = paneState.id
        }
        .contextMenu {
            contextMenuContent
        }
    }

    // MARK: - Pane Content

    @ViewBuilder
    private var paneContent: some View {
        ZStack {
            switch paneState.sessionMode {
            case .independent:
                PaneContainerBridge(
                    paneState: paneState,
                    tab: tab,
                    colorScheme: colorScheme,
                    fontSize: preferences.fontSize,
                    fontFamily: preferences.fontFamily,
                    lineHeight: preferences.lineHeight,
                    scrollbackLines: preferences.scrollbackLines,
                    cursorStyle: cursorStyle,
                    cursorBlink: cursorBlink,
                    copyOnSelect: preferences.copyOnSelect,
                    isActive: isActive,
                    onSend: { data in sendInput(data) },
                    onResize: { cols, rows in resizePTY(cols: cols, rows: rows) },
                    onTitleChange: { _ in },
                    onReconnect: { Task { await sessionManager.reconnectTab(tab.id) } }
                )

            case .linked(let sourceID):
                // Linked mode: show indicator that this pane is linked
                if let sourcePane = tab.layout.findPane(id: sourceID) {
                    PaneContainerBridge(
                        paneState: sourcePane,
                        tab: tab,
                        colorScheme: colorScheme,
                        fontSize: preferences.fontSize,
                        fontFamily: preferences.fontFamily,
                        lineHeight: preferences.lineHeight,
                        scrollbackLines: preferences.scrollbackLines,
                        cursorStyle: cursorStyle,
                        cursorBlink: cursorBlink,
                        copyOnSelect: preferences.copyOnSelect,
                        isActive: isActive,
                        onSend: { data in sendInput(data) },
                        onResize: { cols, rows in resizePTY(cols: cols, rows: rows) },
                        onTitleChange: { _ in },
                        onReconnect: { Task { await sessionManager.reconnectTab(tab.id) } }
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Label("Linked", systemImage: "link")
                            .font(.caption2)
                            .padding(4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                }
            }

            // Drag-and-drop overlay (transparent, handles all drag events)
            DragDropView(
                terminalView: terminalNSView,
                onTabDrop: handleTabDrop,
                onFileDrop: handleFileDrop,
                onDragStateChange: handleDragStateChange
            )
            .allowsHitTesting(true)
        }
        .onAppear {
            // Get terminal view reference for event forwarding
            terminalNSView = TerminalViewCache.shared.retrieve(paneState.id)?.view
        }
    }

    // MARK: - Title Bar

    private var paneTitleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: paneTitleIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(paneState.title.isEmpty ? tab.hostItem.name : paneState.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .onAppear {
                    print("[PANE_TITLE] Pane ID: \(paneState.id), title: '\(paneState.title)', tab hostItem name: '\(tab.hostItem.name)'")
                }

            Spacer()

            // Broadcast toggle button
            Button {
                sessionManager.toggleTabBroadcast(tab.id)
            } label: {
                Image(systemName: tab.isBroadcastEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.caption)
                    .foregroundStyle(tab.isBroadcastEnabled ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(tab.isBroadcastEnabled ? "Disable Broadcast" : "Enable Broadcast")

            // Unsplit button (only show when there are multiple panes)
            if tab.layout.root.paneCount > 1 {
                Button {
                    sessionManager.unsplitPane(paneState.id, from: tab)
                } label: {
                    Image(systemName: "rectangle.split.1x2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(90))
                }
                .buttonStyle(.plain)
                .help("Unsplit (move to new tab)")
            }

            // Close pane button
            Button {
                sessionManager.closePane(paneState.id, in: tab)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(i18n.t(.closePane))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }

    private var paneTitleIcon: String {
        switch paneState.sessionMode {
        case .independent: "terminal"
        case .linked: "link"
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        // Copy/Paste
        Button {
            if let cached = TerminalViewCache.shared.retrieve(paneState.id),
               let selection = cached.view.getSelection(), !selection.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selection, forType: .string)
            }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button {
            if let text = NSPasteboard.general.string(forType: .string) {
                sendInput(ArraySlice(text.utf8))
            }
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }

        Button {
            if let cached = TerminalViewCache.shared.retrieve(paneState.id) {
                cached.view.selectAll()
            }
        } label: {
            Label("Select All", systemImage: "selection.pin.in.out")
        }

        Divider()

        // Split pane options
        Button { sessionManager.splitHorizontal() } label: {
            Label(i18n.t(.splitRight), systemImage: "rectangle.split.1x2")
        }
        Button { sessionManager.splitVertical() } label: {
            Label(i18n.t(.splitDown), systemImage: "rectangle.split.2x1")
        }

        // Broadcast option (only show when there are multiple panes)
        if tab.layout.root.paneCount > 1 {
            Button {
                sessionManager.toggleTabBroadcast(tab.id)
            } label: {
                Label(tab.isBroadcastEnabled ? "Disable Broadcast" : "Enable Broadcast",
                      systemImage: tab.isBroadcastEnabled ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
            }
        }

        Divider()

        // AI Assistant
        Button {
            NotificationCenter.default.post(name: .toggleAIChat, object: nil)
        } label: {
            Label("AI Assistant", systemImage: "sparkles")
        }

        Divider()

        // Close pane
        Button(role: .destructive) {
            sessionManager.closePane(paneState.id, in: tab)
        } label: {
            Label(i18n.t(.closePane), systemImage: "xmark")
        }
        .disabled(tab.layout.root.paneCount <= 1)
    }

    // MARK: - Drop Indicator

    @ViewBuilder
    private var dropIndicator: some View {
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

    // MARK: - Drag Handlers

    private func handleTabDrop(sourceTabID: UUID, position: DropPosition) {
        guard sourceTabID != tab.id else { return }
        sessionManager.addPaneFromTab(sourceTabID, to: tab.id, position: position)
    }

    private func handleFileDrop(urls: [URL]) {
        guard tab.session?.connectionState.isConnected == true else { return }

        for url in urls {
            Task {
                // Clear cached CWD to force fresh path detection
                tab.currentDirectory = nil

                let overwriteAlways = preferences.sftpOverwriteAlways ?? false
                let uploaded = await uploadManager.handleDrop(
                    url: url,
                    tab: tab,
                    overwriteAlways: overwriteAlways,
                    i18n: i18n
                )
                if !uploaded {
                    // File exists, show overwrite dialog
                    pendingUploadURL = url
                    pendingUploadTab = tab
                    showOverwriteAlert = true
                }
            }
        }
    }

    private func handleDragStateChange(isDragging: Bool, position: DropPosition) {
        isDragOver = isDragging
        dropPosition = position
    }

    // MARK: - Helpers

    private func sendInput(_ data: ArraySlice<UInt8>) {
        Task {
            do {
                try await sessionManager.sendInput(data, to: tab.id, paneID: paneState.id)
            } catch {
                sessionManager.lastError = error.localizedDescription
                sessionManager.showError = true
            }
        }
    }

    private func resizePTY(cols: Int, rows: Int) {
        Task {
            do {
                try await sessionManager.resizePTY(cols: cols, rows: rows, tabID: tab.id, paneID: paneState.id)
            } catch {}
        }
    }
}
