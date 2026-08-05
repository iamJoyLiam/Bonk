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

        var body: some View {
            ZStack {
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
                        onTitleChange: onTitleChange
                    )
                case let .reconnecting(attempt, max):
                    reconnectingView(attempt: attempt, max: max)
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
        }

        /// Connect output stream with retry mechanism.
        /// Retries up to 5 times with increasing delay (100ms, 200ms, 400ms, 800ms, 1600ms).
        private func connectOutputStreamWithRetry() {
            Task { @MainActor in
                let maxRetries = 5
                var delay: UInt64 = 100

                for attempt in 0 ..< maxRetries {
                    try? await Task.sleep(for: .milliseconds(Double(delay)))

                    guard let ptySession = paneState.ptySession else {
                        Log.session.debug("[PTY-RETRY] No PTY session yet, retry \(attempt + 1)/\(maxRetries)")
                        delay = min(delay * 2, 1600)
                        continue
                    }

                    let cached = TerminalViewCache.shared.retrieve(paneState.id)
                    if cached?.outputStream == nil {
                        let result = ptySession.makeOutputStream()
                        TerminalViewCache.shared.connectOutputStream(
                            result.stream,
                            onBytesProcessed: result.onBytesProcessed,
                            to: paneState.id
                        )
                        Log.session.info("[PTY-RETRY] Connected output stream on attempt \(attempt + 1)")
                        return
                    } else {
                        // Already connected
                        return
                    }
                }
                Log.session.warning("[PTY-RETRY] Failed to connect output stream after \(maxRetries) attempts")
            }
        }

        private var terminalBackground: SwiftUI.Color {
            SwiftUI.Color(nsColor: .controlBackgroundColor)
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

        func makeCoordinator() -> PaneCoordinator {
            PaneCoordinator()
        }

        func makeNSView(context: Context) -> NSView {
            let containerView = NSView()
            containerView.translatesAutoresizingMaskIntoConstraints = false
            setupTerminalView(for: paneID, in: containerView, context: context)
            return containerView
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            guard context.coordinator.lastPaneID != paneID else {
                if let cached = TerminalViewCache.shared.retrieve(paneID) {
                    updateSettings(for: cached)
                }
                return
            }

            let oldPaneID = context.coordinator.lastPaneID
            context.coordinator.lastPaneID = paneID

            if let oldID = oldPaneID, let oldCached = TerminalViewCache.shared.retrieve(oldID) {
                oldCached.view.removeFromSuperview()
            }

            let cached: CachedTerminalView = if let existing = TerminalViewCache.shared.retrieve(paneID) {
                existing
            } else {
                createTerminalView(for: paneID, context: context)
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

            // Force re-render after re-adding cached view
            cached.view.needsDisplay = true

            Task { @MainActor in try? await Task.sleep(for: .milliseconds(100))
                nsView.window?.makeFirstResponder(cached.view)
            }
        }

        static func dismantleNSView(_: NSView, coordinator _: PaneCoordinator) {}

        private func createSafeFont(family: String, size: CGFloat) -> NSFont {
            guard !family.isEmpty, family != "SF Mono" else {
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            guard let targetFont = NSFont(name: family, size: size) else {
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            return targetFont
        }

        private func createTerminalView(for paneID: UUID, context _: Context) -> CachedTerminalView {
            let font = createSafeFont(family: fontFamily, size: CGFloat(fontSize))
            let terminal = NativeTerminalView(frame: .zero, font: font)
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
            // The pane path previously had no resize propagation after the
            // one-shot post-connect sync, so Vim stayed truncated whenever the
            // final layout differed from that initial size.
            terminal.onPhysicalLayout = { [weak coordinator] cols, rows in
                coordinator?.onResize?(cols, rows)
            }

            coordinator.observeThemeChanges()
            coordinator.installCopyOnSelectMonitor()

            let cached = CachedTerminalView(tabID: paneID, view: terminal, coordinator: coordinator)
            TerminalViewCache.shared.store(tabID: paneID, parentTabID: tabID, view: terminal, coordinator: coordinator)
            return cached
        }

        private func setupTerminalView(for paneID: UUID, in containerView: NSView, context: Context) {
            // Check cache first to preserve terminal state across tab switches
            let cached: CachedTerminalView = if let existing = TerminalViewCache.shared.retrieve(paneID) {
                existing
            } else {
                createTerminalView(for: paneID, context: context)
            }

            cached.view.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(cached.view)

            NSLayoutConstraint.deactivate(cached.constraints)
            cached.constraints = [
                cached.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                cached.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
                cached.view.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
                cached.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4),
            ]
            NSLayoutConstraint.activate(cached.constraints)
            context.coordinator.lastPaneID = paneID

            // Force re-render after re-adding cached view to view hierarchy
            cached.view.needsDisplay = true

            Task { @MainActor in try? await Task.sleep(for: .milliseconds(100))
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
            // Update color scheme when theme changes
            applyColorScheme(to: terminal, scheme: colorScheme)
        }
    }

    private class PaneCoordinator: NSObject {
        var lastPaneID: UUID?
    }
#endif
