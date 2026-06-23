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
        let onSend: @Sendable (ArraySlice<UInt8>) -> Void
        let onResize: (@Sendable (Int, Int) -> Void)?
        let onTitleChange: (@Sendable (String) -> Void)?
        let onReconnect: (() -> Void)?

        var body: some View {
            ZStack {
                switch activeTab.session?.connectionState ?? .disconnected {
                case .disconnected:
                    disconnectedView
                case .connecting:
                    connectingView
                case .connected:
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
                        onSend: onSend,
                        onResize: onResize,
                        onTitleChange: onTitleChange
                    )
                case let .reconnecting(attempt, max):
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
            .onAppear {
                connectOutputStreamIfNeeded()
            }
        }

        private func connectOutputStreamIfNeeded() {
            guard let ptySession = activeTab.session?.ptySession else { return }
            let cached = TerminalViewCache.shared.retrieve(activeTab.id)
            if cached?.outputStream == nil {
                let result = ptySession.makeOutputStream()
                TerminalViewCache.shared.connectOutputStream(
                    result.stream,
                    onBytesProcessed: result.onBytesProcessed,
                    to: activeTab.id
                )
            }
        }

        private var terminalBackground: SwiftUI.Color {
            if colorScheme.id == "transparent" { return .clear }
            return SwiftUI.Color(nsColor: .controlBackgroundColor)
        }

        private var connectingView: some View {
            VStack(spacing: 20) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue.opacity(0.7))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                ProgressView().controlSize(.large)
                VStack(spacing: 6) {
                    Text(i18n.tr(.connectingTo, args: activeTab.hostItem.host))
                        .font(.headline)
                    Text("\(activeTab.hostItem.username)@\(activeTab.hostItem.host):\(activeTab.hostItem.port)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }

        private var disconnectedView: some View {
            VStack(spacing: 16) {
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red.opacity(0.6))
                Text(i18n.t(.disconnected)).font(.headline)
                if let error = activeTab.session?.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 300)
                }
                if let onReconnect {
                    Button(i18n.t(.reconnect), systemImage: "arrow.clockwise") { onReconnect() }
                        .buttonStyle(.borderedProminent).padding(.top, 8)
                }
            }
        }

        private func reconnectingView(attempt: Int, max: Int) -> some View {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(i18n.tr(.reconnecting, args: attempt, max))
                    .font(.headline).foregroundStyle(.secondary)
            }
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
            }

            let cached: CachedTerminalView = if let existing = TerminalViewCache.shared.retrieve(activeTabID) {
                existing
            } else {
                createTerminalView(for: activeTabID, context: context)
            }

            cached.view.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(cached.view)

            NSLayoutConstraint.deactivate(cached.constraints)

            cached.constraints = [
                cached.view.leadingAnchor.constraint(equalTo: nsView.leadingAnchor, constant: 8),
                cached.view.trailingAnchor.constraint(equalTo: nsView.trailingAnchor, constant: -8),
                cached.view.topAnchor.constraint(equalTo: nsView.topAnchor, constant: 4),
                cached.view.bottomAnchor.constraint(equalTo: nsView.bottomAnchor, constant: -4),
            ]
            NSLayoutConstraint.activate(cached.constraints)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                nsView.window?.makeFirstResponder(cached.view)
            }
        }

        static func dismantleNSView(_: NSView, coordinator _: ContainerCoordinator) {}

        // MARK: - Helpers

        private func createSafeFont(family: String, size: CGFloat) -> NSFont {
            guard !family.isEmpty, family != "SF Mono" else {
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            guard let targetFont = NSFont(name: family, size: size) else {
                Log.ui.warning("Font '\(family)' not found, falling back to system monospaced")
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            return targetFont
        }

        private func createTerminalView(for tabID: UUID, context _: Context) -> CachedTerminalView {
            let font = createSafeFont(family: fontFamily, size: CGFloat(fontSize))
            let terminal = SwiftTerm.TerminalView(frame: .zero, font: font)
            terminal.configureNativeColors()

            applyColorScheme(to: terminal, scheme: colorScheme)
            terminal.terminal.changeScrollback(scrollbackLines)
            terminal.terminal.setCursorStyle(mapCursorStyle(cursorStyle, blink: cursorBlink))

            let coordinator = ContainerTerminalCoordinator(
                onSend: onSend,
                onResize: onResize,
                onTitleChange: onTitleChange,
                copyOnSelect: copyOnSelect,
                sessionID: tabID.uuidString
            )
            terminal.terminalDelegate = coordinator
            coordinator.terminalView = terminal

            coordinator.observeThemeChanges()
            coordinator.installCopyOnSelectMonitor()
            TerminalScrollFix.register(terminal)

            let cached = CachedTerminalView(tabID: tabID, view: terminal, coordinator: coordinator)
            TerminalViewCache.shared.store(tabID: tabID, view: terminal, coordinator: coordinator)

            return cached
        }

        private func setupTerminalView(for tabID: UUID, in containerView: NSView, context: Context) {
            let cached = createTerminalView(for: tabID, context: context)
            cached.view.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(cached.view)

            cached.constraints = [
                cached.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                cached.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
                cached.view.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
                cached.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4),
            ]
            NSLayoutConstraint.activate(cached.constraints)
            context.coordinator.lastTabID = tabID

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                containerView.window?.makeFirstResponder(cached.view)
            }
        }

        private func updateSettings(for cached: CachedTerminalView) {
            let terminal = cached.view
            let newFont = createSafeFont(family: fontFamily, size: CGFloat(fontSize))

            terminal.font = newFont

            terminal.terminal.setCursorStyle(mapCursorStyle(cursorStyle, blink: cursorBlink))
            if terminal.terminal.options.scrollback != scrollbackLines {
                terminal.terminal.changeScrollback(scrollbackLines)
            }
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
        var fontObserver: NSObjectProtocol?

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
            feedTask?.cancel()
        }

        // MARK: - Copy on Select

        func installCopyOnSelectMonitor() {
            guard copyOnSelect else { return }
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self, let terminal = terminalView else { return event }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if terminal.selectionActive {
                        if let selectedText = terminal.getSelection(), !selectedText.isEmpty {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(selectedText, forType: .string)
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
    }

#endif
