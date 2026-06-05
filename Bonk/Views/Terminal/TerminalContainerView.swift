//
//  TerminalContainerView.swift
//  Bonk
//
//  AppKit container that manages terminal view switching without destroying views.
//

import SwiftUI
import SwiftTerm
import os

#if os(macOS)
import AppKit

/// SwiftUI view that hosts the AppKit container.
struct TerminalContainerView: View {
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
            switch activeTab.connectionState {
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
            case .reconnecting(let attempt, let max):
                reconnectingView(attempt: attempt, max: max)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground)
        .onChange(of: activeTab.ptySession != nil) { _, hasSession in
            if hasSession {
                connectOutputStreamIfNeeded()
            }
        }
        .onAppear {
            connectOutputStreamIfNeeded()
        }
    }

    private func connectOutputStreamIfNeeded() {
        guard let ptySession = activeTab.ptySession else { return }
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
                Text("Connecting to \(activeTab.hostItem.host)...")
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
            Text("Disconnected").font(.headline)
            if let error = activeTab.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
            }
            if let onReconnect {
                Button("Reconnect", systemImage: "arrow.clockwise") { onReconnect() }
                    .buttonStyle(.borderedProminent).padding(.top, 8)
            }
        }
    }

    private func reconnectingView(attempt: Int, max: Int) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Reconnecting (\(attempt)/\(max))...")
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
            // Tab didn't change, just update settings
            if let cached = TerminalViewCache.shared.retrieve(activeTabID) {
                let tv = cached.view
                // 验证：cache 返回的 view 是否在当前窗口的子视图树中
                let isInHierarchy = tv.superview != nil
                let isSubviewOfContainer = nsView.subviews.contains(tv)
                updateSettings(for: cached)
                // Update copy-on-select monitor when setting changes
                if let coord = cached.coordinator as? ContainerTerminalCoordinator {
                    coord.updateCopyOnSelect(copyOnSelect)
                }
            } else {
            }
            return
        }

        let oldTabID = context.coordinator.lastTabID
        context.coordinator.lastTabID = activeTabID

        // 1. Remove old terminal view from container (keep in cache)
        if let oldID = oldTabID, let oldCached = TerminalViewCache.shared.retrieve(oldID) {
            oldCached.view.removeFromSuperview()
        }

        // 2. Get or create new terminal view
        let cached: CachedTerminalView
        if let existing = TerminalViewCache.shared.retrieve(activeTabID) {
            cached = existing
        } else {
            cached = createTerminalView(for: activeTabID, context: context)
        }

        // 3. Add to container with constraints (with padding)
        cached.view.translatesAutoresizingMaskIntoConstraints = false
        nsView.addSubview(cached.view)

        // Remove old constraints if any
        NSLayoutConstraint.deactivate(cached.constraints)

        // Create new constraints with padding
        cached.constraints = [
            cached.view.leadingAnchor.constraint(equalTo: nsView.leadingAnchor, constant: 8),
            cached.view.trailingAnchor.constraint(equalTo: nsView.trailingAnchor, constant: -8),
            cached.view.topAnchor.constraint(equalTo: nsView.topAnchor, constant: 4),
            cached.view.bottomAnchor.constraint(equalTo: nsView.bottomAnchor, constant: -4)
        ]
        NSLayoutConstraint.activate(cached.constraints)

        // 4. Focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            nsView.window?.makeFirstResponder(cached.view)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ContainerCoordinator) {
        // Don't clear cache - views persist
    }

    // MARK: - Helpers

    /// Create a safe font with nil-checking and fallback to system monospaced font.
    /// Prevents silent failure when a font name doesn't match any installed font.
    private func createSafeFont(family: String, size: CGFloat) -> NSFont {
        guard !family.isEmpty, family != "SF Mono" else {
            // SF Mono is the system monospaced font, use the system API directly
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        guard let targetFont = NSFont(name: family, size: size) else {
            print("[TerminalContainerView] WARNING: Font '\(family)' not found, falling back to system monospaced")
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return targetFont
    }

    private func createTerminalView(for tabID: UUID, context: Context) -> CachedTerminalView {
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
            copyOnSelect: copyOnSelect
        )
        terminal.terminalDelegate = coordinator
        coordinator.terminalView = terminal

        // Note: Output stream needs to be connected externally
        // The container will receive output via the feed task when connected

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

        // Store constraints for later management
        cached.constraints = [
            cached.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            cached.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            cached.view.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
            cached.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4)
        ]
        NSLayoutConstraint.activate(cached.constraints)
        context.coordinator.lastTabID = tabID

        // Focus the terminal when first created
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            containerView.window?.makeFirstResponder(cached.view)
        }
    }

    private func updateSettings(for cached: CachedTerminalView) {
        let terminal = cached.view
        let newFont = createSafeFont(family: fontFamily, size: CGFloat(fontSize))

        let oldFont = terminal.font

        terminal.font = newFont

        let afterFont = terminal.font

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
    nonisolated(unsafe) var feedTask: Task<Void, Never>?
    private var themeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mouseUpMonitor: Any?
    private var fontObserver: NSObjectProtocol?

    // Batch feed throttling — reduces MainActor.run calls under heavy output
    private let batchBuffer = OSAllocatedUnfairLock<String>(uncheckedState: "")
    private let batchFlushScheduled = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
    private static let batchThreshold = 4096  // 4 KB — flush immediately when buffer reaches this size

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

    init(onSend: @escaping @Sendable (ArraySlice<UInt8>) -> Void, onResize: (@Sendable (Int, Int) -> Void)?, onTitleChange: (@Sendable (String) -> Void)?, copyOnSelect: Bool) {
        self._onSend = onSend
        self._onResize = onResize
        self._onTitleChange = onTitleChange
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
            guard let self, let terminal = self.terminalView else { return event }
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

    /// Update copy-on-select when the setting changes at runtime.
    func updateCopyOnSelect(_ enabled: Bool) {
        copyOnSelect = enabled
        if enabled && mouseUpMonitor == nil {
            installCopyOnSelectMonitor()
        } else if !enabled && mouseUpMonitor != nil {
            removeCopyOnSelectMonitor()
        }
    }

    func startFeeding(from stream: AsyncStream<String>, onBytesProcessed: (@Sendable (Int) -> Void)? = nil) {
        // Cancel existing feed task before creating new one
        feedTask?.cancel()
        // Reset batch state
        batchBuffer.withLock { $0 = "" }
        batchFlushScheduled.withLock { $0 = false }

        feedTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(150))
            for await text in stream {
                guard !Task.isCancelled else { break }
                let byteCount = text.utf8.count
                let shouldFlush = self.batchBuffer.withLock { buf -> Bool in
                    buf += text
                    return buf.utf8.count >= Self.batchThreshold
                }
                if shouldFlush {
                    self.flushBatch()
                } else {
                    self.scheduleFlush()
                }
                onBytesProcessed?(byteCount)
            }
        }
    }

    private func scheduleFlush() {
        let alreadyScheduled = batchFlushScheduled.withLock { val -> Bool in
            if !val { val = true; return false }
            return true
        }
        guard !alreadyScheduled else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            self?.flushBatch()
        }
    }

    private func flushBatch() {
        batchFlushScheduled.withLock { $0 = false }
        let text = batchBuffer.withLock { buf -> String in
            let t = buf
            buf = ""
            return t
        }
        guard !text.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.terminalView?.feed(text: text)
        }
    }

    func observeThemeChanges() {
        // Font changes — bypass SwiftUI observation chain (same pattern as theme)
        fontObserver = NotificationCenter.default.addObserver(forName: .terminalFontDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let self, let terminal = self.terminalView else { return }
            let fontFamily = (notification.object as? String) ?? "SF Mono"
            let fontSize = (notification.userInfo?["fontSize"] as? Double) ?? 14.0
            let size = CGFloat(fontSize)
            let newFont: NSFont
            switch fontFamily {
            case "Menlo":
                newFont = NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            case "Monaco":
                newFont = NSFont(name: "Monaco", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            case "Courier New":
                newFont = NSFont(name: "Courier New", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            case "JetBrains Mono":
                newFont = NSFont(name: "JetBrains Mono", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            default:
                newFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            terminal.font = newFont
            terminal.needsDisplay = true
        }

        themeObserver = NotificationCenter.default.addObserver(forName: .terminalThemeDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let self, let terminal = self.terminalView, let scheme = notification.object as? TerminalColorScheme else { return }
            terminal.nativeBackgroundColor = scheme.background.nsColor
            terminal.nativeForegroundColor = scheme.foreground.nsColor
            terminal.installColors(scheme.swiftTermColors)
        }

        // Selection request → respond with selected text
        NotificationCenter.default.addObserver(
            forName: .requestTerminalSelection,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let terminal = self.terminalView else { return }
            let selectedText = terminal.getSelection()
            NotificationCenter.default.post(name: .terminalSelectionResponse, object: selectedText)
        }

        // Select all text in terminal
        NotificationCenter.default.addObserver(
            forName: .selectAllInTerminal,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let terminal = self.terminalView else { return }
            terminal.selectAll()
        }

        // Focus terminal
        NotificationCenter.default.addObserver(
            forName: .focusTerminal,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let terminal = self.terminalView else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    func removeThemeObserver() {
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
            themeObserver = nil
        }
        if let observer = fontObserver {
            NotificationCenter.default.removeObserver(observer)
            fontObserver = nil
        }
    }

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { onSend(data) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { onResize?(newCols, newRows) }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { onTitleChange?(title) }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func bell(source: SwiftTerm.TerminalView) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(content, forType: .string)
    }
    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

#endif
