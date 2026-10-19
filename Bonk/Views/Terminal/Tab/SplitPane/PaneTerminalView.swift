//
//  PaneTerminalView.swift
//  Bonk
//
//  A single pane in the layout, supporting independent and linked modes.
//

import AppKit
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
    /// Survives the body refresh that the drop indicator itself causes.
    @State private var dropSession = PaneDropDelegate.Session()
    /// Pane size, so a drop position can be resolved from the pointer location.
    @State private var paneSize: CGSize = .zero
    @State var terminalNSView: NSView?
    @State var isRecording = false

    // Upload state
    let uploadManager = UploadManager.shared
    @ObservedObject private var teamRelay = TeamRelay.shared
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
            // Upload progress overlay — scoped to this tab so another
            // tab's upload never leaks its progress bar in here.
            if let msg = uploadManager.message(for: tab.id) {
                VStack(spacing: 4) {
                    Text(msg)
                        .font(.caption)
                        .lineLimit(1)

                    if let progress = uploadManager.progress(for: tab.id) {
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
        .background {
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusLarge, style: .continuous)
                .fill(paneSurface)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusLarge, style: .continuous))
        .onTapGesture {
            focusManager.focus(paneState.id)
            tab.activePaneID = paneState.id
        }
        .contextMenu {
            contextMenuContent
        }
        .task { await refreshRecordingState() }
        .onChange(of: paneState.ptySession?.recordingPaneID) { _, _ in Task { await refreshRecordingState() } }
        .onAppear { updateTeamSubscription() }
        .onChange(of: teamRelay.sharedSessionID) { _, _ in updateTeamSubscription() }
        .onChange(of: teamRelay.isHosting) { _, _ in updateTeamSubscription() }
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
        }
        // Drop registration lives on the pane container, not on an overlay.
        // An overlay that returns nil from hitTest is a *sibling* of the
        // terminal, and a drop target must be the hit view or an ancestor of it,
        // so the pane was never a reachable drop target.
        .background {
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size, initial: true) { _, newValue in
                    paneSize = newValue
                }
            }
        }
        .onDrop(
            of: PaneDropDelegate.acceptedTypes,
            delegate: PaneDropDelegate(
                currentTabID: tab.id,
                sizeProvider: { paneSize },
                onTabDrop: handleTabDrop,
                onFileDrop: handleFileDrop,
                onDragStateChange: handleDragStateChange,
                session: dropSession
            )
        )
        .overlay(alignment: .topTrailing) {
            TeamStatusOverlay(relay: teamRelay)
                .padding(.top, 6)
                .padding(.trailing, 8)
                .allowsHitTesting(false)
        }
        .onAppear {
            terminalNSView = TerminalViewCache.shared.retrieveForPane(paneID: paneState.id, tabID: tab.id)?.view
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
        .padding(.vertical, AppStyle.spacingS)
        .background(paneSurface)
    }

    /// The working card is paper. An idle card is the light gray.
    private var paneSurface: SwiftUI.Color {
        Color(nsColor: PaneChrome.surface(isActive: isActive))
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

    @MainActor
    private func updateTeamSubscription() {
        guard let cached = TerminalViewCache.shared.retrieveForPane(paneID: paneState.id, tabID: tab.id),
              let coordinator = cached.coordinator as? ContainerTerminalCoordinator else { return }
        // Only the shared pane (host) broadcasts; guest never broadcasts
        if teamRelay.isHosting, let shared = teamRelay.sharedSessionID, shared.paneID == paneState.id {
            coordinator.updateTeamSubscription(sessionID: shared)
        } else {
            coordinator.updateTeamSubscription(sessionID: nil)
        }
    }
}

/// Which surface a split pane uses.
///
/// The working pane is the paper color. An idle pane is the system gray, and
/// when that token resolves to the same white as the window it is shaded so
/// the pane cannot disappear into the background.
enum PaneChrome {
    /// Blend toward black when the system gray is not actually darker than the window.
    private static let idleShade: CGFloat = 0.14
    /// An idle pane has to be at least this much darker than the window to count as gray.
    private static let minimumContrast: CGFloat = 0.04
    static func surface(isActive: Bool) -> NSColor {
        let appearance = NSApp.effectiveAppearance
        var chosen = NSColor.controlBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            let paper = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) ?? .white
            if isActive {
                chosen = paper
                return
            }
            let gray = NSColor.unemphasizedSelectedContentBackgroundColor.usingColorSpace(.sRGB)
            let window = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            if let gray, let window, luminance(gray) + minimumContrast < luminance(window) {
                chosen = gray
            } else if let window {
                chosen = window.blended(withFraction: idleShade, of: .black) ?? gray ?? paper
            } else {
                chosen = gray ?? paper
            }
        }
        return chosen
    }

    /// A light theme can take the card color as its background and stay readable.
    /// A dark theme cannot: the gray card would sit under light-colored text.
    static func adoptsCardBackground(_ scheme: TerminalColorScheme) -> Bool {
        luminance(scheme.background.nsColor) > 0.5
    }

    /// Relative luminance, so the comparison does not depend on one appearance.
    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        let red = 0.2126 * rgb.redComponent
        let green = 0.7152 * rgb.greenComponent
        let blue = 0.0722 * rgb.blueComponent
        return red + green + blue
    }
}
