//
//  PaneContainerBridge.swift
//  Bonk
//
//  Bridges PaneState to TerminalContainerView.
//

import os.log
import SwiftTerm
import SwiftUI

#if os(macOS)
    import AppKit

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

        /// Lazily gathers terminal context for inline AI completion.
        private var completionContext: @MainActor () -> InlineCompletionContext {
            { [weak tab] in
                let output = tab?.session?.ptySession?.recentOutput(maxLines: 40) ?? ""
                let hostKey = tab?.hostItem.id.uuidString
                let history = GlobalCommandHistory.shared.commands.filter {
                    $0.hostKey == hostKey
                }
                return InlineCompletionContext(
                    inputBuffer: tab?.session?.inputBuffer ?? "",
                    hostKey: hostKey,
                    currentDirectory: tab?.currentDirectory,
                    shell: tab?.session?.serverInfo?.shell,
                    recentCommands: history.suffix(50).map(\.command),
                    recentOutput: output,
                    lastExitCode: history.last?.exitCode,
                    knownWords: InlineCompletionService.extractKnownWords(from: output)
                )
            }
        }

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
                            completionContext: completionContext,
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
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalPTYSessionReady)) { note in
                if let tid = note.userInfo?["tabID"] as? UUID, tid == tab.id {
                    connectOutputStreamWithRetry()
                }
            }
        }

        /// Connect output stream with retry mechanism.
        /// Retries until both the PTY session and the terminal view exist
        /// (increasing delay, ~30s window), then attaches the output stream.
        /// FIX: cancel previous retry task when a new connection starts (wrong→correct password)
        /// FIX: defer @State mutation to next run loop to avoid "Modifying state during view update" (#112).
        private func connectOutputStreamWithRetry() {
            // Wrap in Task to ensure @State assignment happens outside SwiftUI's view update phase
            // (called from updateNSView/onViewReady which runs during view update).
            Task { @MainActor in
                self.retryTask?.cancel()
                self.retryTask = Task { @MainActor in
                    let maxRetries = 10
                    var delay: UInt64 = 100

                    for attempt in 0 ..< maxRetries {
                        if Task.isCancelled { Log.session.info("[PTY-RETRY] cancelled at attempt \(attempt + 1)"); return }
                        // If tab already failed/disconnected, no PTY will ever appear — stop retrying
                        if let state = tab.session?.connectionState, case .disconnected = state {
                            if let phase = tab.session?.phase, case .failed = phase { Log.session.info("[PTY-RETRY] tab failed, abort retry"); return }
                        }
                        try? await Task.sleep(for: .milliseconds(Double(delay)))
                        if Task.isCancelled { return }

                        guard let ptySession = paneState.ptySession else {
                            Log.session.info("[PTY-RETRY] No PTY session yet, retry \(attempt + 1)/\(maxRetries)")
                            delay = min(delay * 2, 1600)
                            continue
                        }

                        let cached = TerminalViewCache.shared.retrieve(paneState.id)
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
                                to: paneState.id
                            )
                            if let coord = cached.coordinator as? ContainerTerminalCoordinator { coord.hostItem = tab.hostItem }
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
        let completionContext: (@MainActor () -> InlineCompletionContext)?
        /// Fired every time this bridge attaches a terminal view for a pane.
        /// SwiftUI reuses the surrounding container across tab switches, so
        /// onAppear is unreliable — updateNSView is the reliable hook.
        let onViewReady: () -> Void

        func makeCoordinator() -> PaneCoordinator {
            PaneCoordinator()
        }

        func makeNSView(context: Context) -> NSView {
            let containerView = NSView()
            containerView.translatesAutoresizingMaskIntoConstraints = false
            setupTerminalView(for: paneID, in: containerView, context: context)
            onViewReady()
            return containerView
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            guard context.coordinator.lastPaneID != paneID else {
                if let cached = TerminalViewCache.shared.retrieve(paneID) {
                    updateSettings(for: cached, coordinator: context.coordinator)
                }
                return
            }

            let oldPaneID = context.coordinator.lastPaneID
            context.coordinator.lastPaneID = paneID

            if let oldID = oldPaneID, let oldCached = TerminalViewCache.shared.retrieve(oldID) {
                oldCached.view.removeFromSuperview()
            }

            let cached: CachedTerminalView
            let created: Bool
            if let existing = TerminalViewCache.shared.retrieve(paneID) {
                cached = existing
                created = false
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

            // Force re-render after re-adding cached view
            cached.view.needsDisplay = true
            onViewReady()

            Task { @MainActor in try? await Task.sleep(for: .milliseconds(100))
                nsView.window?.makeFirstResponder(cached.view)
            }
        }

        static func dismantleNSView(_: NSView, coordinator _: PaneCoordinator) {}

        private func createTerminalView(for paneID: UUID, context _: Context) -> CachedTerminalView {
            let font = createSafeFont(family: fontFamily, size: CGFloat(fontSize))
            let terminal = NativeTerminalView(frame: .zero, font: font)
            terminal.configureNativeColors()
            terminal.completionContextProvider = completionContext

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

            let cached = CachedTerminalView(tabID: paneID, view: terminal, coordinator: coordinator)
            TerminalViewCache.shared.store(tabID: paneID, parentTabID: tabID, view: terminal, coordinator: coordinator)
            // If this pane is already the shared one (restore path), subscribe team immediately
            if TeamRelay.shared.isHosting, TeamRelay.shared.sharedSessionID?.paneID == paneID,
               let sid = TeamRelay.shared.sharedSessionID {
                Task { @MainActor in coordinator.updateTeamSubscription(sessionID: sid) }
            }
            return cached
        }

        private func setupTerminalView(for paneID: UUID, in containerView: NSView, context: Context) {
            // Check cache first to preserve terminal state across tab switches
            let cached: CachedTerminalView
            let created: Bool
            if let existing = TerminalViewCache.shared.retrieve(paneID) {
                cached = existing
                created = false
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
                   let sid = TeamRelay.shared.sharedSessionID {
                    Task { @MainActor in tCoord.updateTeamSubscription(sessionID: sid) }
                } else {
                    Task { @MainActor in tCoord.updateTeamSubscription(sessionID: nil) }
                }
            }

            Task { @MainActor in try? await Task.sleep(for: .milliseconds(100))
                containerView.window?.makeFirstResponder(cached.view)
            }
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
        var lastPaneID: UUID?
        var lastColorSchemeID: String?
    }
#endif
