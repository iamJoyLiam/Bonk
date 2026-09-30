//
//  PaneContainerBridge.swift
//  Bonk
//
//  Bridges PaneState to TerminalContainerView.
//

import os.log
import SwiftData
import SwiftTerm
import SwiftUI

#if os(macOS)
    import AppKit

    /// Signpost for measuring the tab-selection path in Instruments.
    /// Filter: subsystem "com.bonk", category "TerminalPerf", event "PaneRebind".
    private let perfSignposter = OSSignposter(
        subsystem: "com.bonk",
        category: "TerminalPerf"
    )

    /// Bridges PaneState to TerminalContainerView.
    struct PaneContainerBridge: View {
        let paneState: PaneState
        let tab: TerminalTab
        @State private var retryTask: Task<Void, Never>?
        let colorScheme: TerminalColorScheme
        let fontSize: Double
        let fontFamily: String
        let lineHeight: Double
        let scrollbackLines: Int
        let cursorStyle: String
        let cursorBlink: Bool
        let copyOnSelect: Bool
        let isActive: Bool
        let onSend: @Sendable (ArraySlice<UInt8>) -> Void
        let onResize: (@Sendable (Int, Int) -> Void)?
        let onTitleChange: (@Sendable (String) -> Void)?
        let onReconnect: (() -> Void)?

        /// Intelligence-owned snapshot provider — one instance per pane, holds KnownWords/history cache.
        @State private var contextProvider = WorkspaceContextProvider()

        /// Intelligence-owned snapshot provider (single source of truth)
        private var commandSnapshot: @MainActor () -> CommandContextSnapshot {
            { [weak tab, contextProvider] in
                guard let tab else { return CommandContextSnapshot(inputBuffer: "") }
                return contextProvider.snapshot(for: tab)
            }
        }

        @State private var inlinePipeline = InlineSuggestionPipeline()
        @Environment(\.modelContext) private var modelContext

        var body: some View {
            ZStack {
                if tab.session?.connectionState == .connected, paneState.ptySession == nil {
                    // Split restore race: tab connected but this pane has no PTY yet
                    connectingView
                } else {
                    switch tab.session?.connectionState ?? .disconnected {
                    case .disconnected:
                        disconnectedView
                    case .connecting:
                        connectingView
                    case .connected:
                        PaneMacBridge(
                            paneID: paneState.id,
                            tabID: tab.id,
                            isActive: isActive,
                            colorScheme: colorScheme,
                            fontSize: fontSize,
                            fontFamily: fontFamily,
                            lineHeight: lineHeight,
                            scrollbackLines: scrollbackLines,
                            cursorStyle: cursorStyle,
                            cursorBlink: cursorBlink,
                            copyOnSelect: copyOnSelect,
                            onSend: onSend,
                            onResize: onResize,
                            onTitleChange: onTitleChange,
                            commandSnapshot: commandSnapshot,
                            inlinePipeline: inlinePipeline,
                            onViewReady: connectOutputStreamWithRetry
                        )
                    case let .reconnecting(attempt, max):
                        reconnectingView(attempt: attempt, max: max)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(terminalBackground)
            .onChange(of: paneState.ptySession != nil) { _, hasSession in
                if hasSession {
                    connectOutputStreamWithRetry()
                }
            }
            .onAppear {
                connectOutputStreamWithRetry()
                inlinePipeline.attachModelContext(modelContext)
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalPTYSessionReady)) { note in
                if let tid = note.userInfo?["tabID"] as? UUID, tid == tab.id {
                    connectOutputStreamWithRetry()
                }
            }
        }

        /// Connect output stream with retry mechanism.
        /// Retries until both the PTY session and the terminal view exist
        /// (increasing delay, ~21s window: transport timeout is 10s plus a
        /// possible compatibility-fallback round, so the view must outwait
        /// a slow-but-legit connect), then attaches the output stream.
        /// FIX: cancel previous retry task when a new connection starts (wrong→correct password)
        /// FIX: defer @State mutation to next run loop to avoid "Modifying state during view update" (#112).
        private func connectOutputStreamWithRetry() {
            // Wrap in Task to ensure @State assignment happens outside SwiftUI's view update phase
            // (called from updateNSView/onViewReady which runs during view update).
            Task { @MainActor in
                self.retryTask?.cancel()
                self.retryTask = Task { @MainActor in
                    let maxRetries = 16
                    var delay: UInt64 = 100

                    for attempt in 0 ..< maxRetries {
                        if Task.isCancelled {
                            Log.session.info("[PTY-RETRY] cancelled at attempt \(attempt + 1)"); return
                        }
                        // If tab already failed/disconnected, no PTY will ever appear — stop retrying
                        if let state = tab.session?.connectionState, case .disconnected = state {
                            if let phase = tab.session?.phase, case .failed = phase {
                                Log.session.info("[PTY-RETRY] tab failed, abort retry"); return
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(Double(delay)))
                        if Task.isCancelled {
                            return
                        }

                        guard let ptySession = paneState.ptySession else {
                            Log.session.info("[PTY-RETRY] No PTY session yet, retry \(attempt + 1)/\(maxRetries)")
                            delay = min(delay * 2, 1600)
                            continue
                        }

                        let cached = TerminalViewCache.shared.retrieveForPane(paneID: paneState.id, tabID: tab.id)
                        guard let cached else {
                            // View created after this task started — wait for it.
                            Log.session.info("[PTY-RETRY] Terminal view not cached yet, retry \(attempt + 1)/\(maxRetries)")
                            delay = min(delay * 2, 1600)
                            continue
                        }

                        if cached.outputStream == nil {
                            let result = ptySession.makeOutputStream(host: tab.hostItem)
                            TerminalViewCache.shared.connectOutputStream(
                                result.stream,
                                onBytesProcessed: result.onBytesProcessed,
                                to: TerminalViewCacheKey.pane(paneState.id, in: tab.id)
                            )
                            if let coord = cached.coordinator as? ContainerTerminalCoordinator {
                                coord.hostItem = tab.hostItem
                            }
                            Log.session.info("[PTY-RETRY] Connected output stream on attempt \(attempt + 1)")
                            return
                        }
                        // Already connected
                        if let coordinator = cached.coordinator as? ContainerTerminalCoordinator,
                           coordinator.feedTask == nil,
                           let stream = cached.outputStream,
                           let bytesProcessed = cached.onBytesProcessed
                        {
                            Log.session.info("[PTY-RETRY] Output stream exists but feed task nil, restarting for pane \(paneState.id.uuidString.prefix(8))")
                            coordinator.hostItem = tab.hostItem
                            coordinator.startFeeding(from: stream, onBytesProcessed: bytesProcessed)
                        } else {
                            Log.session.info("[PTY-RETRY] Already connected for pane \(paneState.id.uuidString.prefix(8))")
                        }
                        return
                    }
                    Log.session.warning("[PTY-RETRY] Failed to connect output stream after \(maxRetries) attempts")
                }
            }
        }

        private var terminalBackground: SwiftUI.Color {
            SwiftUI.Color(nsColor: colorScheme.background.nsColor)
        }

        @Environment(I18n.self) var i18n

        private var connectingView: some View {
            TerminalStateViews.connectingView(
                host: tab.hostItem.host,
                username: tab.hostItem.username,
                port: tab.hostItem.port,
                i18n: i18n
            )
        }

        private var disconnectedView: some View {
            TerminalStateViews.disconnectedView(
                errorMessage: tab.session?.errorMessage,
                i18n: i18n,
                onReconnect: onReconnect
            )
        }

        private func reconnectingView(attempt: Int, max: Int) -> some View {
            TerminalStateViews.reconnectingView(attempt: attempt, max: max, i18n: i18n)
        }
    }

    /// AppKit bridge for a single pane.
    private struct PaneMacBridge: NSViewRepresentable {
        let paneID: UUID
        let tabID: UUID
        /// Whether this pane is the tab's active one. Only a tiebreak in size
        /// arbitration — it never outranks focus.
        let isActive: Bool
        let colorScheme: TerminalColorScheme
        let fontSize: Double
        let fontFamily: String
        let lineHeight: Double
        let scrollbackLines: Int
        let cursorStyle: String
        let cursorBlink: Bool
        let copyOnSelect: Bool
        let onSend: @Sendable (ArraySlice<UInt8>) -> Void
        let onResize: (@Sendable (Int, Int) -> Void)?
        let onTitleChange: (@Sendable (String) -> Void)?
        let commandSnapshot: (@MainActor () -> CommandContextSnapshot)?
        let inlinePipeline: InlineSuggestionPipeline?
        /// Fired every time this bridge attaches a terminal view for a pane.
        /// SwiftUI reuses the surrounding container across tab switches, so
        /// onAppear is unreliable — updateNSView is the reliable hook.
        let onViewReady: () -> Void

        func makeCoordinator() -> PaneCoordinator {
            PaneCoordinator(tabID: tabID)
        }

        func makeNSView(context: Context) -> NSView {
            let containerView = NSView()
            containerView.translatesAutoresizingMaskIntoConstraints = false
            setupTerminalView(for: paneID, in: containerView, context: context)
            registerViewportAuthority(for: paneID)
            onViewReady()
            return containerView
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            let signpostStart = perfSignposter.beginInterval("PaneRebind")
            defer { perfSignposter.endInterval("PaneRebind", signpostStart) }
            guard context.coordinator.lastPaneID != paneID else {
                if let cached = TerminalViewCache.shared.retrieveForPane(paneID: paneID, tabID: tabID) {
                    updateSettings(for: cached, coordinator: context.coordinator)
                    registerViewportAuthority(for: paneID)
                }
                return
            }

            let oldPaneID = context.coordinator.lastPaneID
            context.coordinator.lastPaneID = paneID

            if let oldID = oldPaneID, let oldCached = TerminalViewCache.shared.retrieveForPane(paneID: oldID, tabID: tabID) {
                // Same as the single-pane bridge: clear stale selection on switch-away so old text can't be re-copied by later clicks.
                oldCached.view.selectNone()
                oldCached.view.removeFromSuperview()
                // And drop its claim on the PTY's size. A pane that is no longer
                // mounted must not stay the authority, or a split that no longer
                // shows it would still be setting the PTY's size.
                if let oldCoord = oldCached.coordinator as? ContainerTerminalCoordinator {
                    oldCoord.removeViewportFocusObserver()
                    TerminalViewportRegistry.shared.unregister(
                        .pane(oldID),
                        in: TerminalViewportRegistry.PTYKey(tabID: tabID, paneID: oldID)
                    )
                    oldCoord.viewportOwner = nil
                    oldCoord.viewportPTYKey = nil
                }
            }

            let cached: CachedTerminalView
            let created: Bool
            if let existing = TerminalViewCache.shared.retrieveForPane(paneID: paneID, tabID: tabID) {
                cached = existing
                created = false
                if let native = cached.view as? NativeTerminalView {
                    native.commandSnapshotProvider = commandSnapshot
                    native.inlinePipeline = inlinePipeline
                }
                rebindCallbacks(for: cached)
            } else {
                cached = createTerminalView(for: paneID, context: context)
                created = true
            }
            if created {
                context.coordinator.lastColorSchemeID = colorScheme.id
            }

            cached.view.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(cached.view)

            NSLayoutConstraint.deactivate(cached.constraints)
            cached.constraints = [
                cached.view.leadingAnchor.constraint(equalTo: nsView.leadingAnchor, constant: terminalViewInsets.left),
                cached.view.trailingAnchor.constraint(equalTo: nsView.trailingAnchor, constant: -terminalViewInsets.right),
                cached.view.topAnchor.constraint(equalTo: nsView.topAnchor, constant: terminalViewInsets.top),
                cached.view.bottomAnchor.constraint(equalTo: nsView.bottomAnchor, constant: -terminalViewInsets.bottom),
            ]
            NSLayoutConstraint.activate(cached.constraints)

            updateSettings(for: cached, coordinator: context.coordinator)
            registerViewportAuthority(for: paneID)

            // Force re-render after re-adding cached view
            cached.view.needsDisplay = true
            onViewReady()

            scheduleFocus(of: cached.view, in: nsView, coordinator: context.coordinator)
        }

        /// Focus the pane after layout settles. Cancels any pending focus so
        /// rapid tab switches do not stack competing makeFirstResponder calls.
        private func scheduleFocus(of view: NSView, in container: NSView, coordinator: PaneCoordinator) {
            coordinator.focusTask?.cancel()
            coordinator.focusTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                container.window?.makeFirstResponder(view)
            }
        }

        static func dismantleNSView(_: NSView, coordinator: PaneCoordinator) {
            coordinator.focusTask?.cancel()
            coordinator.focusTask = nil
            // Leaving a mounted-looking claim behind would keep this pane's
            // view as its PTY's size authority after the view is gone.
            guard let paneID = coordinator.lastPaneID,
                  let cached = TerminalViewCache.shared.retrieveForPane(paneID: paneID, tabID: coordinator.tabID),
                  let coord = cached.coordinator as? ContainerTerminalCoordinator,
                  let owner = coord.viewportOwner,
                  let ptyKey = coord.viewportPTYKey
            else { return }
            coord.removeViewportFocusObserver()
            TerminalViewportRegistry.shared.unregister(owner, in: ptyKey)
            coord.viewportOwner = nil
            coord.viewportPTYKey = nil
        }
        /// A view moved between panes/tabs keeps its coordinator, but the
        /// coordinator's callbacks still point at the pane it was created for.
        /// Rebind them so input/resize reach the pane that now owns the view —
        /// otherwise SIGWINCH goes to the old PTY and the new one keeps a stale
        /// column count, truncating wide output.
        ///
        /// The synced size is deliberately NOT invalidated here. A genuine size
        /// change already publishes itself: `layout()` reads `terminal.cols`
        /// after `super.layout()` has resized it, so it differs from the last
        /// published value. Invalidating would additionally force a redundant
        /// publish at unchanged size on every tab switch — an SSH window-change
        /// round trip plus a full repaint in vim/top, which reads as a dropped
        /// frame when switching tabs quickly.
        private func rebindCallbacks(for cached: CachedTerminalView) {
            guard let coordinator = cached.coordinator as? ContainerTerminalCoordinator else { return }
            let send = onSend
            let resize = onResize
            let titleChange = onTitleChange
            coordinator.onSend = { data in send(data) }
            coordinator.onResize = { cols, rows in resize?(cols, rows) }
            coordinator.onTitleChange = { title in titleChange?(title) }
        }

        private func createTerminalView(for paneID: UUID, context _: Context) -> CachedTerminalView {
            let font = createSafeFont(family: fontFamily, size: CGFloat(fontSize))
            let terminal = NativeTerminalView(frame: .zero, font: font)
            terminal.configureNativeColors()
            terminal.commandSnapshotProvider = commandSnapshot
            terminal.inlinePipeline = inlinePipeline

            // Scrollbar: hidden initially, show on scroll, small
            for subview in terminal.subviews {
                if let scroller = subview as? NSScroller {
                    scroller.controlSize = .small
                    scroller.alphaValue = 0.0
                }
            }

            applyColorScheme(to: terminal, scheme: colorScheme)
            terminal.terminal.changeScrollback(scrollbackLines)
            terminal.terminal.setCursorStyle(mapCursorStyle(cursorStyle, blink: cursorBlink))

            let coordinator = ContainerTerminalCoordinator(
                onSend: onSend,
                onResize: onResize,
                onTitleChange: onTitleChange,
                copyOnSelect: copyOnSelect,
                sessionID: paneID.uuidString
            )
            terminal.terminalDelegate = coordinator
            coordinator.terminalView = terminal

            // Core fix: intercept AppKit physical layout for accurate PTY sync.
            // Route through Engine for single-watermark coalescing.
            terminal.onPhysicalLayout = { [weak coordinator] cols, rows in
                coordinator?.handleResize(cols: cols, rows: rows)
            }

            coordinator.observeThemeChanges()
            coordinator.installCopyOnSelectMonitor()
            coordinator.installInlineCompletionMonitor()

            let cached = CachedTerminalView(tabID: tabID, view: terminal, coordinator: coordinator)
            TerminalViewCache.shared.store(
                TerminalViewCacheKey.pane(paneID, in: tabID),
                view: terminal,
                coordinator: coordinator
            )
            // If this pane is already the shared one (restore path), subscribe team immediately
            if TeamRelay.shared.isHosting, TeamRelay.shared.sharedSessionID?.paneID == paneID,
               let sid = TeamRelay.shared.sharedSessionID
            {
                Task { @MainActor in coordinator.updateTeamSubscription(sessionID: sid) }
            }
            return cached
        }

        /// Declare this pane's view as a candidate for its PTY's size.
        ///
        /// A pane owns its PTY outright, so the registry key is the pane
        /// itself. This view is the main window's view of it — the one that
        /// competes with the Quake panel when both are on screen.
        private func registerViewportAuthority(for paneID: UUID) {
            let key = TerminalViewportRegistry.PTYKey(tabID: tabID, paneID: paneID)
            var size: TerminalViewportSize?
            if let cached = TerminalViewCache.shared.retrieveForPane(paneID: paneID, tabID: tabID) {
                size = TerminalViewportSize(
                    cols: cached.view.terminal.cols, rows: cached.view.terminal.rows
                )
            }
            TerminalViewportRegistry.shared.register(
                .pane(paneID),
                for: key,
                isVisible: true,
                isActive: isActive,
                size: size
            )
            if let coord = TerminalViewCache.shared.retrieveForPane(paneID: paneID, tabID: tabID)?
                .coordinator as? ContainerTerminalCoordinator {
                coord.viewportOwner = .pane(paneID)
                coord.viewportPTYKey = key
                coord.installViewportFocusObserver()
            }
        }

        private func setupTerminalView(for paneID: UUID, in containerView: NSView, context: Context) {
            // Check cache first to preserve terminal state across tab switches
            let cached: CachedTerminalView
            let created: Bool
            if let existing = TerminalViewCache.shared.retrieveForPane(paneID: paneID, tabID: tabID) {
                cached = existing
                created = false
                if let native = cached.view as? NativeTerminalView {
                    native.commandSnapshotProvider = commandSnapshot
                    native.inlinePipeline = inlinePipeline
                }
                rebindCallbacks(for: cached)
            } else {
                cached = createTerminalView(for: paneID, context: context)
                created = true
            }
            if created {
                context.coordinator.lastColorSchemeID = colorScheme.id
            }

            cached.view.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(cached.view)

            NSLayoutConstraint.deactivate(cached.constraints)
            cached.constraints = [
                cached.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: terminalViewInsets.left),
                cached.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -terminalViewInsets.right),
                cached.view.topAnchor.constraint(equalTo: containerView.topAnchor, constant: terminalViewInsets.top),
                cached.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -terminalViewInsets.bottom),
            ]
            NSLayoutConstraint.activate(cached.constraints)
            context.coordinator.lastPaneID = paneID
            updateSettings(for: cached, coordinator: context.coordinator)

            // Force re-render after re-adding cached view to view hierarchy
            cached.view.needsDisplay = true
            // Ensure team subscription matches current shared pane (covers restore + cache reuse)
            if let tCoord = cached.coordinator as? ContainerTerminalCoordinator {
                if TeamRelay.shared.isHosting, TeamRelay.shared.sharedSessionID?.paneID == paneID,
                   let sid = TeamRelay.shared.sharedSessionID
                {
                    Task { @MainActor in tCoord.updateTeamSubscription(sessionID: sid) }
                } else {
                    Task { @MainActor in tCoord.updateTeamSubscription(sessionID: nil) }
                }
            }

            scheduleFocus(of: cached.view, in: containerView, coordinator: context.coordinator)
        }

        private func updateSettings(for cached: CachedTerminalView, coordinator: PaneCoordinator) {
            let terminal = cached.view
            let newFont = createSafeFont(family: fontFamily, size: CGFloat(fontSize))
            if !terminal.font.isEqual(newFont) {
                terminal.font = newFont
            }
            terminal.terminal.setCursorStyle(mapCursorStyle(cursorStyle, blink: cursorBlink))
            if terminal.terminal.options.scrollback != scrollbackLines {
                terminal.terminal.changeScrollback(scrollbackLines)
            }
            // Update color scheme only when it actually changed.
            if coordinator.lastColorSchemeID != colorScheme.id {
                applyColorScheme(to: terminal, scheme: colorScheme)
                coordinator.lastColorSchemeID = colorScheme.id
            }
        }
    }

    private class PaneCoordinator: NSObject {
        /// The tab this coordinator belongs to, so teardown can name the PTY it
        /// has to release without reaching back into the representable.
        let tabID: UUID
        var lastPaneID: UUID?
        var lastColorSchemeID: String?

        init(tabID: UUID) {
            self.tabID = tabID
        }
        /// Pending delayed focus. Cancelled on rebind so rapid tab switches do
        /// not stack up competing makeFirstResponder calls.
        var focusTask: Task<Void, Never>?
    }
#endif
