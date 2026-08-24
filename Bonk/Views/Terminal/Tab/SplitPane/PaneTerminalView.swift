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
    @State var isRecording = false
    @State private var showBlocks = false

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
        .overlay {
            // Drag-and-drop overlay with indicator
            dropIndicator
                .allowsHitTesting(false)
                .opacity(isDragOver ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isDragOver)
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
                            .frame(maxWidth: AppStyle.size200)
                    }
                }
                .padding(.horizontal, AppStyle.spacingL)
                .padding(.vertical, AppStyle.spacingS)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, AppStyle.spacingL)
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
        .task { await refreshRecordingState() }
        .onChange(of: paneState.ptySession?.recordingPaneID) { _, _ in Task { await refreshRecordingState() } }
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
                    onSend: { data in Task { @MainActor in sendInput(data) } },
                    onResize: { cols, rows in Task { @MainActor in resizePTY(cols: cols, rows: rows) } },
                    onTitleChange: { _ in },
                    onReconnect: { Task { await sessionManager.reconnectTab(tab.id) } }
                )

            case .linked:
                // Linked mode: reuse the same PTY session but keep a separate
                // TerminalView per pane. Previous code reused sourcePane's cached
                // NSView (sourcePane.id), which moves the view to the second
                // container and leaves the source pane blank — exactly the
                // “single cursor” bug in the screenshot.
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
                    onSend: { data in Task { @MainActor in sendInput(data) } },
                    onResize: { cols, rows in Task { @MainActor in resizePTY(cols: cols, rows: rows) } },
                    onTitleChange: { _ in },
                    onReconnect: { Task { await sessionManager.reconnectTab(tab.id) } }
                )
                .overlay(alignment: .bottomTrailing) {
                    Label(i18n.t(.linked), systemImage: "link")
                        .font(.caption2)
                        .padding(AppStyle.spacingXS)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(AppStyle.spacingXS)
                }
            }

            // Drag-and-drop overlay (transparent, handles all drag events)
            DragDropView(
                terminalView: terminalNSView,
                currentTabID: tab.id,
                onTabDrop: handleTabDrop,
                onFileDrop: handleFileDrop,
                onDragStateChange: handleDragStateChange
            )
            .allowsHitTesting(true)

            // Command blocks drawer (Warp-style)
            if showBlocks {
                HStack { Spacer() 
                    CommandBlocksPanel(paneID: paneState.id, ptySession: paneState.ptySession, isPresented: $showBlocks)
                        .frame(maxHeight: .infinity)
                        .padding(8)
                        .shadow(radius: 8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                .background(Color.black.opacity(0.15).allowsHitTesting(true).onTapGesture { withAnimation { showBlocks = false } })
            }

            // Floating blocks button for single-pane (title bar hidden)
            if tab.layout.root.paneCount == 1 {
                VStack {
                    HStack {
                        Spacer()
                        Button { withAnimation { showBlocks.toggle() } } label: {
                            let count = paneState.ptySession?.allCommandBlocks().count ?? 0
                            HStack(spacing: 3) {
                                Image(systemName: "rectangle.grid.1x2").font(.caption)
                                if count > 0 { Text("\(count)").font(.caption2) }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(showBlocks ? Color.blue : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Command Blocks")
                        .padding(.top, 6).padding(.trailing, 8)
                    }
                    Spacer()
                }
                .allowsHitTesting(true)
            }
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
                .foregroundStyle(isActive ? .primary : .secondary)
            Text(paneState.title.isEmpty ? tab.hostItem.name : paneState.title)
                .font(.caption)
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)

            Spacer()

            if isRecording {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text(i18n.t(.rec)).font(.caption2).foregroundStyle(.red)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.red.opacity(0.12), in: Capsule())
                .help(i18n.t(.stopRecording))
            }

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
            .help(tab.isBroadcastEnabled ? i18n.t(.disableBroadcast) : i18n.t(.enableBroadcast))

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

            // Command blocks toggle (Warp-style)
            Button { withAnimation { showBlocks.toggle() } } label: {
                let count = paneState.ptySession?.allCommandBlocks().count ?? 0
                HStack(spacing: 3) {
                    Image(systemName: "rectangle.grid.1x2").font(.caption)
                    if count > 0 { Text("\(count)").font(.caption2) }
                }
                .foregroundStyle(showBlocks ? Color.blue : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Command Blocks")

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
        .padding(.horizontal, AppStyle.spacingML)
        .padding(.vertical, AppStyle.spacingXS)
        .background(isActive ? Color(nsColor: .controlBackgroundColor).opacity(AppStyle.opacityDisabled) : Color.clear)
    }

    private var paneTitleIcon: String {
        switch paneState.sessionMode {
        case .independent: "terminal"
        case .linked: "link"
        }
    }

    func refreshRecordingState() async {
        isRecording = await SessionRecordingService.shared.isRecording(paneID: paneState.id)
    }
}
