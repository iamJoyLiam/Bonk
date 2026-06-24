//
//  PaneTerminalView.swift
//  Bonk
//
//  A single pane in the layout, supporting independent and linked modes.
//

import SwiftTerm
import SwiftUI

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

    @State var focusManager = FocusManager.shared
    @State var isDragOver = false
    @State var dropPosition: DropPosition = .right
    @State var terminalNSView: NSView?

    // Upload state
    let uploadManager = UploadManager.shared
    @State var pendingUploadURL: URL?
    @State var pendingUploadTab: TerminalTab?
    @State var showOverwriteAlert = false

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
            pendingUploadURL.map { i18n.tr(.fileExists, args: $0.lastPathComponent) } ?? "",
            isPresented: $showOverwriteAlert
        ) {
            Button(i18n.t(.overwrite)) {
                guard let url = pendingUploadURL, let tab = pendingUploadTab else { return }
                pendingUploadURL = nil; pendingUploadTab = nil
                showOverwriteAlert = false
                Task { await uploadManager.performUpload(url, tab: tab, i18n: i18n) }
            }
            Button(i18n.t(.alwaysOverwrite)) {
                guard let url = pendingUploadURL, let tab = pendingUploadTab else { return }
                pendingUploadURL = nil; pendingUploadTab = nil
                showOverwriteAlert = false
                preferences.sftpOverwriteAlways = true
                Task { await uploadManager.performUpload(url, tab: tab, i18n: i18n) }
            }
            Button(i18n.t(.cancel), role: .cancel) {
                pendingUploadURL = nil; pendingUploadTab = nil
                showOverwriteAlert = false
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

            case let .linked(sourceID):
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

            Spacer()

            // Broadcast toggle button
            Button {
                sessionManager.toggleTabBroadcast(tab.id)
            } label: {
                let iconName = tab.isBroadcastEnabled
                    ? "antenna.radiowaves.left.and.right"
                    : "antenna.radiowaves.left.and.right.slash"
                Image(systemName: iconName)
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
}
