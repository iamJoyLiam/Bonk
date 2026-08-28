//
//  TerminalContainerView.swift
//  Bonk
//
//  AppKit container that manages terminal view switching without destroying views.
//

import os
import SwiftTerm
import SwiftUI

#if os(macOS)
    import AppKit

    /// SwiftUI view that hosts the AppKit container.
    struct TerminalContainerView: View {
        @Environment(I18n.self) var i18n
        let activeTab: TerminalTab
        let colorScheme: TerminalColorScheme
        let fontSize: Double
        let fontFamily: String
        let lineHeight: Double
        let scrollbackLines: Int
        let cursorStyle: String
        let cursorBlink: Bool
        let copyOnSelect: Bool
        let scrollSensitivity: Double
        let onSend: @Sendable (ArraySlice<UInt8>) -> Void
        let onResize: (@Sendable (Int, Int) -> Void)?
        let onTitleChange: (@Sendable (String) -> Void)?
        let onReconnect: (() -> Void)?

        var body: some View {
            ZStack {
                let phase = activeTab.session?.phase ?? .idle
                switch phase {
                case .idle, .failed:
                    disconnectedView
                case .resolving, .connectingTransport, .negotiatingSSH, .authenticating, .fallbacking, .openingChannel:
                    TerminalStateViews.fallbackingView(for: phase, host: activeTab.hostItem.host, username: activeTab.hostItem.username, port: activeTab.hostItem.port, i18n: i18n)
                case .ready:
                    if activeTab.session?.terminalState == .ready {
                        MacTerminalContainerBridge(
                            activeTabID: activeTab.id,
                            colorScheme: colorScheme,
                            fontSize: fontSize,
                            fontFamily: fontFamily,
                            lineHeight: lineHeight,
                            scrollbackLines: scrollbackLines,
                            cursorStyle: cursorStyle,
                            cursorBlink: cursorBlink,
                            copyOnSelect: copyOnSelect,
                            scrollSensitivity: scrollSensitivity,
                            onSend: onSend,
                            onResize: onResize,
                            onTitleChange: onTitleChange
                        )
                    } else {
                        connectingView
                    }
                case .reconnecting(let attempt, let max):
                    reconnectingView(attempt: attempt, max: max)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(terminalBackground)
            .onChange(of: activeTab.session?.ptySession != nil) { _, hasSession in
                if hasSession {
                    connectOutputStreamIfNeeded()
                }
            }
            .onChange(of: activeTab.id) { _, _ in
                connectOutputStreamIfNeeded()
            }
            .onAppear {
                connectOutputStreamIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalPTYSessionReady)) { notification in
                if let tabID = notification.userInfo?["tabID"] as? UUID, tabID == activeTab.id {
                    connectOutputStreamIfNeeded()
                }
            }
        }

        private func connectOutputStreamIfNeeded() {
            guard let ptySession = activeTab.session?.ptySession else {
                Log.ui.warning("[TerminalContainer] connectOutputStreamIfNeeded: no PTY session for tab \(activeTab.id.uuidString.prefix(8))")
                return
            }
            let cached = TerminalViewCache.shared.retrieve(activeTab.id)
            if let coord = cached?.coordinator as? ContainerTerminalCoordinator { coord.hostItem = activeTab.hostItem }
            if cached?.outputStream == nil {
                Log.ui.info("[TerminalContainer] connectOutputStreamIfNeeded: creating output stream for tab \(activeTab.id.uuidString.prefix(8))")
                let result = ptySession.makeOutputStream(host: activeTab.hostItem)
                TerminalViewCache.shared.connectOutputStream(
                    result.stream,
                    onBytesProcessed: result.onBytesProcessed,
                    to: activeTab.id
                )
                if let coord = cached?.coordinator as? ContainerTerminalCoordinator { coord.hostItem = activeTab.hostItem }
            } else if let coordinator = cached?.coordinator as? ContainerTerminalCoordinator,
                      coordinator.feedTask == nil,
                      let stream = cached?.outputStream,
                      let bytesProcessed = cached?.onBytesProcessed
            {
                Log.ui.info("[TerminalContainer] connectOutputStreamIfNeeded: feed task nil for tab \(activeTab.id.uuidString.prefix(8)), restarting")
                coordinator.hostItem = activeTab.hostItem
                coordinator.startFeeding(from: stream, onBytesProcessed: bytesProcessed)
            }
        }

        private var terminalBackground: SwiftUI.Color {
            SwiftUI.Color(nsColor: colorScheme.background.nsColor)
        }

        private var connectingView: some View {
            TerminalStateViews.connectingView(
                host: activeTab.hostItem.host,
                username: activeTab.hostItem.username,
                port: activeTab.hostItem.port,
                i18n: i18n
            )
        }

        private var disconnectedView: some View {
            TerminalStateViews.disconnectedView(
                errorMessage: activeTab.session?.errorMessage,
                i18n: i18n,
                onReconnect: onReconnect
            )
        }

        private func reconnectingView(attempt: Int, max: Int) -> some View {
            TerminalStateViews.reconnectingView(attempt: attempt, max: max, i18n: i18n)
        }
    }

    /// AppKit container that manages terminal view switching.
    private struct MacTerminalContainerBridge: NSViewRepresentable {
        let activeTabID: UUID
        let colorScheme: TerminalColorScheme
        let fontSize: Double
        let fontFamily: String
        let lineHeight: Double
        let scrollbackLines: Int
        let cursorStyle: String
        let cursorBlink: Bool
        let copyOnSelect: Bool
        let scrollSensitivity: Double
        let onSend: @Sendable (ArraySlice<UInt8>) -> Void
        let onResize: (@Sendable (Int, Int) -> Void)?
        let onTitleChange: (@Sendable (String) -> Void)?

        func makeCoordinator() -> ContainerCoordinator {
            ContainerCoordinator()
        }

        func makeNSView(context: Context) -> NSView {
            let containerView = NSView()
            containerView.translatesAutoresizingMaskIntoConstraints = false
            setupTerminalView(for: activeTabID, in: containerView, context: context)
            return containerView
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            guard context.coordinator.lastTabID != activeTabID else {
                if let cached = TerminalViewCache.shared.retrieve(activeTabID) {
                    updateSettings(for: cached)
                    if let coord = cached.coordinator as? ContainerTerminalCoordinator {
                        coord.updateCopyOnSelect(copyOnSelect)
                    }
                }
                return
            }

            let oldTabID = context.coordinator.lastTabID
            context.coordinator.lastTabID = activeTabID

            if let oldID = oldTabID, let oldCached = TerminalViewCache.shared.retrieve(oldID) {
                oldCached.view.removeFromSuperview()
                if let oldCoord = oldCached.coordinator as? ContainerTerminalCoordinator {
                    oldCoord.removeCopyOnSelectMonitor()
                    oldCoord.removeInlineCompletionMonitor()
                }
            }

            let cached: CachedTerminalView
            if let existing = TerminalViewCache.shared.retrieve(activeTabID) {
                cached = existing
            } else {
                Log.ui.info("[TerminalContainer] Cache miss for tab \(activeTabID.uuidString.prefix(8)), creating new view")
                cached = createTerminalView(for: activeTabID, context: context)
            }

            cached.view.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(cached.view)
            if let coord = cached.coordinator as? ContainerTerminalCoordinator {
                coord.installCopyOnSelectMonitor()
                coord.installInlineCompletionMonitor()
            }

            NSLayoutConstraint.deactivate(cached.constraints)

            cached.constraints = [
                cached.view.leadingAnchor.constraint(equalTo: nsView.leadingAnchor, constant: terminalViewInsets.left),
                cached.view.trailingAnchor.constraint(equalTo: nsView.trailingAnchor, constant: -terminalViewInsets.right),
                cached.view.topAnchor.constraint(equalTo: nsView.topAnchor, constant: terminalViewInsets.top),
                cached.view.bottomAnchor.constraint(equalTo: nsView.bottomAnchor, constant: -terminalViewInsets.bottom),
            ]
            NSLayoutConstraint.activate(cached.constraints)

            // Force re-render after re-adding cached view
            cached.view.needsDisplay = true
            nsView.window?.makeFirstResponder(cached.view)
            // PTY sync is now handled by NativeTerminalView.layout() — no manual intervention needed
        }

        static func dismantleNSView(_: NSView, coordinator _: ContainerCoordinator) {}

        // MARK: - Helpers

        private func createTerminalView(for tabID: UUID, context _: Context) -> CachedTerminalView {
            let font = createSafeFont(family: fontFamily, size: CGFloat(fontSize))
            let terminal = NativeTerminalView(frame: .zero, font: font)
            terminal.bellStyle = .none
            terminal.configureNativeColors()

            // 滚动条：初始隐藏，滚动时显示，使用小尺寸
            for subview in terminal.subviews {
                if let scroller = subview as? NSScroller {
                    scroller.controlSize = .small
                    scroller.alphaValue = 0.0
                }
            }

            applyColorScheme(to: terminal, scheme: colorScheme)
            terminal.terminal.changeScrollback(scrollbackLines)
            terminal.terminal.setCursorStyle(mapCursorStyle(cursorStyle, blink: cursorBlink))
            // Set scroll sensitivity for native scrolling (SwiftTerm 1.15.0+)
            terminal.scrollSensitivityMultiplier = CGFloat(self.scrollSensitivity)

            let coordinator = ContainerTerminalCoordinator(
                onSend: onSend,
                onResize: onResize,
                onTitleChange: onTitleChange,
                copyOnSelect: copyOnSelect,
                sessionID: tabID.uuidString
            )
            terminal.terminalDelegate = coordinator
            coordinator.terminalView = terminal

            // Core fix: intercept AppKit physical layout for accurate PTY sync
            // Route through Engine so resize coalesces with display tick (single watermark path)
            terminal.onPhysicalLayout = { [weak coordinator] cols, rows in
                coordinator?.handleResize(cols: cols, rows: rows)
            }

            coordinator.observeThemeChanges()
            coordinator.installCopyOnSelectMonitor()
            coordinator.installInlineCompletionMonitor()

            let cached = CachedTerminalView(tabID: tabID, view: terminal, coordinator: coordinator)
            TerminalViewCache.shared.store(tabID: tabID, view: terminal, coordinator: coordinator)

            return cached
        }

        private func setupTerminalView(for tabID: UUID, in containerView: NSView, context: Context) {
            let cached = createTerminalView(for: tabID, context: context)
            cached.view.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(cached.view)

            cached.constraints = [
                cached.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: terminalViewInsets.left),
                cached.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -terminalViewInsets.right),
                cached.view.topAnchor.constraint(equalTo: containerView.topAnchor, constant: terminalViewInsets.top),
                cached.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -terminalViewInsets.bottom),
            ]
            NSLayoutConstraint.activate(cached.constraints)
            context.coordinator.lastTabID = tabID

            // Force re-render after adding view
            cached.view.needsDisplay = true
            containerView.window?.makeFirstResponder(cached.view)
            // PTY sync is now handled by NativeTerminalView.layout() — no manual intervention needed
        }

        private func updateSettings(for cached: CachedTerminalView) {
            let terminal = cached.view
            let newFont = createSafeFont(family: fontFamily, size: CGFloat(fontSize))

            terminal.font = newFont

            terminal.terminal.setCursorStyle(mapCursorStyle(cursorStyle, blink: cursorBlink))
            if terminal.terminal.options.scrollback != scrollbackLines {
                terminal.terminal.changeScrollback(scrollbackLines)
            }
            // Update color scheme when theme changes
            applyColorScheme(to: terminal, scheme: colorScheme)
        }
    }

    /// Coordinator for the container.
    private class ContainerCoordinator: NSObject {
        var lastTabID: UUID?
    }

    /// Terminal coordinator for container-managed views.
    class ContainerTerminalCoordinator: NSObject, SwiftTerm.TerminalViewDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _onSend: @Sendable (ArraySlice<UInt8>) -> Void
        private var _onResize: (@Sendable (Int, Int) -> Void)?
        private var _onTitleChange: (@Sendable (String) -> Void)?
        private var copyOnSelect: Bool
        nonisolated(unsafe) weak var terminalView: SwiftTerm.TerminalView?
        private var _feedTask: Task<Void, Never>?
        var themeObserver: NSObjectProtocol?
        private nonisolated(unsafe) var mouseUpMonitor: Any?
        private nonisolated(unsafe) var completionKeyMonitor: Any?
        var fontObserver: NSObjectProtocol?
        var selectionObserver: NSObjectProtocol?
        var selectAllObserver: NSObjectProtocol?
        var focusObserver: NSObjectProtocol?
        // Engine seam — one per coordinator, display-synced via shared source
        nonisolated(unsafe) var terminalEngine: TerminalEngine?
        nonisolated(unsafe) var engineConsumerID: UUID?
        nonisolated(unsafe) var engineConsumer: (any TerminalConsumer)?
        nonisolated(unsafe) var teamConsumerID: UUID?
        nonisolated(unsafe) var teamConsumer: (any TerminalConsumer)?
        nonisolated(unsafe) var hostItem: HostItem?
        /// Access engine only on MainActor; creates lazily.
        @MainActor func getOrCreateEngine() -> TerminalEngine {
            if let e = terminalEngine { return e }
            let e = TerminalEngine(displaySource: AppKitDisplaySource.shared)
            e.onResize = { [weak self] cols, rows in self?.onResize?(cols, rows) }
            terminalEngine = e
            return e
        }

        /// Team is a second subscriber on the same Engine — same tick, same watermark, same colorization point.
        @MainActor func updateTeamSubscription(sessionID: TeamSessionID?) {
            let engine = getOrCreateEngine()
            // Remove previous
            if let old = teamConsumerID {
                engine.unsubscribe(old)
                teamConsumerID = nil
                teamConsumer = nil
            }
            guard let sessionID else { return }
            let id = UUID()
            let consumer = TeamTerminalConsumer(sessionID: sessionID, host: hostItem)
            teamConsumer = consumer
            teamConsumerID = id
            engine.subscribe(id, consumer: consumer)
        }

        var feedTask: Task<Void, Never>? {
            get { lock.lock(); defer { lock.unlock() }; return _feedTask }
            set { lock.lock(); defer { lock.unlock() }; _feedTask = newValue }
        }

        let batchBuffer = OSAllocatedUnfairLock<String>(uncheckedState: "")
        let batchFlushScheduled = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        static let batchThreshold = 16384 // Increased from 4096 to 16KB for better performance

        var onSend: @Sendable (ArraySlice<UInt8>) -> Void {
            get { lock.lock(); defer { lock.unlock() }; return _onSend }
            set { lock.lock(); defer { lock.unlock() }; _onSend = newValue }
        }

        var onResize: (@Sendable (Int, Int) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _onResize }
            set { lock.lock(); defer { lock.unlock() }; _onResize = newValue }
        }

        var onTitleChange: (@Sendable (String) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _onTitleChange }
            set { lock.lock(); defer { lock.unlock() }; _onTitleChange = newValue }
        }

        /// Resize via Engine (coalesced; single watermark path). Safe to call from any thread.
        func handleResize(cols: Int, rows: Int) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.getOrCreateEngine().resize(cols: cols, rows: rows)
            }
        }

        init(
            onSend: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
            onResize: (@Sendable (Int, Int) -> Void)?,
            onTitleChange: (@Sendable (String) -> Void)?,
            copyOnSelect: Bool,
            sessionID _: String? = nil
        ) {
            _onSend = onSend
            _onResize = onResize
            _onTitleChange = onTitleChange
            self.copyOnSelect = copyOnSelect
        }

        deinit {
            removeThemeObserver()
            removeCopyOnSelectMonitor()
            removeInlineCompletionMonitor()
            feedTask?.cancel()
        }

        // MARK: - Copy on Select

        func installCopyOnSelectMonitor() {
            guard copyOnSelect else { return }
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self, let terminal = terminalView else { return event }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if terminal.selectionActive {
                        if let selectedText = terminal.getSelection(), !selectedText.isEmpty {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(selectedText, forType: .string)
                            NotificationCenter.default.post(name: .showCopyMessage, object: nil)
                        }
                    }
                }
                return event
            }
        }

        func removeCopyOnSelectMonitor() {
            if let monitor = mouseUpMonitor {
                NSEvent.removeMonitor(monitor)
                mouseUpMonitor = nil
            }
        }

        func updateCopyOnSelect(_ enabled: Bool) {
            copyOnSelect = enabled
            if enabled, mouseUpMonitor == nil {
                installCopyOnSelectMonitor()
            } else if !enabled, mouseUpMonitor != nil {
                removeCopyOnSelectMonitor()
            }
        }

        // MARK: - Inline Completion Keys

        /// Intercept Tab/Esc while an inline suggestion is shown. The monitor
        /// runs before SwiftTerm's keyDown, so the event can be swallowed
        /// entirely (Tab accept / Esc dismiss) without reaching the terminal.
        func installInlineCompletionMonitor() {
            guard completionKeyMonitor == nil else { return }
            completionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let view = terminalView as? NativeTerminalView else { return event }
                return view.processKeyEvent(event)
            }
        }

        func removeInlineCompletionMonitor() {
            if let monitor = completionKeyMonitor {
                NSEvent.removeMonitor(monitor)
                completionKeyMonitor = nil
            }
        }
    }

#endif
