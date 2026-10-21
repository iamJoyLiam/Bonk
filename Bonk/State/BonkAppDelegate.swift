//
//  BonkAppDelegate.swift
//  Bonk
//
//  AppKit-owned main window, following TablePro's proven architecture:
//
//  - The window is created by the app delegate (NSWindow), NOT by SwiftUI's
//    WindowGroup, so SwiftUI's AppKitWindowController never manages it and
//    never installs its own toolbar (no BarAppearanceBridge / displayMode
//    KVO, no "Cannot remove an observer" crash).
//  - The content is an NSSplitViewController (sidebar / detail / inspector)
//    hosting SwiftUI views, so SwiftUI contributes no toolbar content.
//  - Our custom NSToolbar is the only toolbar; a keep-alive observer restores
//    it if anything ever replaces it.
//

import AppKit
import os.log
import SwiftData
import SwiftUI

@MainActor
final class BonkAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak static var shared: BonkAppDelegate?
    private var mainWindow: NSWindow?
    private var toolbarDelegate: BonkToolbarDelegate?
    private var toolbar: NSToolbar?
    private var toolbarObservation: NSKeyValueObservation?
    /// Stops a titlebar clear from re-entering layout.
    private var matchingTitlebar = false
    /// Liquid glass behind the page and the toolbar. One view, so the bar
    /// and the gutter are the same material.
    private var glassBackdrop: NSView?
    var sessionManager: SessionManager?
    var workspace: WorkspaceManager?
    var coordinator: ToolbarCoordinator?

    // MARK: - Launch

    func applicationDidFinishLaunching(_: Notification) {
        Self.shared = self
        CrashReporter.install()
        // Reclaim PTYs held by orphaned bonk-ssh mux processes from a
        // previous crashed/killed session (no live connections exist yet).
        #if os(macOS)
            OpenSSHBackend.cleanupOrphanedMuxes()
        #endif
        applyTheme()

        let i18n = I18n.shared
        let workspace = WorkspaceManager()
        let sessionManager = SessionManager()
        self.sessionManager = sessionManager
        // One responder owns the terminal-selection round trip for the whole
        // process. Placing it on a terminal view instead meant split tabs had no
        // responder at all, and the reply it did send was always empty.
        TerminalSelectionResponder(sessionManager: sessionManager).start()
        self.workspace = workspace
        let coordinator = ToolbarCoordinator(
            workspace: workspace,
            sessionManager: sessionManager,
            i18n: i18n
        )
        self.coordinator = coordinator
        toolbarDelegate = BonkToolbarDelegate(coordinator: coordinator)

        // A test run boots the real app, because the app hosts the test
        // bundle. Opening the main window there would take over the
        // developer's screen mid-work, and the Quake panel would come up on
        // top of it. The services above are what tests actually use, so the
        // window is the only thing withheld.
        if TestEnvironment.isRunningTests { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.minSize = NSSize(width: 900, height: 600)
        #if DEBUG
            // DEBUG builds use an in-memory store: data dies with the process.
            // Mark the window so a dev build is never mistaken for production.
            window.title = "Bonk (DEBUG · In-Memory Mode)"
        #else
            window.title = "Bonk"
        #endif
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BonkMainWindow")
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .none

        // Read the saved frame up front: once the contentViewController is
        // installed, SwiftUI layout constraints squeeze the window to its
        // minimum (900x600) and AppKit autosaves that squeezed frame on
        // first display, clobbering the user's saved size. Restoring from
        // this early snapshot after display (but before any user resize)
        // would read the already-clobbered value, so apply it manually.
        let savedFrameString = UserDefaults.standard
            .string(forKey: "NSWindow Frame BonkMainWindow")

        let splitVC = MainSplitViewController(
            workspace: workspace,
            sessionManager: sessionManager,
            i18n: i18n,
            coordinator: coordinator,
            modelContainer: BonkApp.sharedModelContainer
        )
        window.contentViewController = splitVC
        if let savedFrameString {
            let parts = savedFrameString.split(separator: " ").compactMap { Double($0) }
            if parts.count >= 4 {
                window.setFrame(
                    NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]),
                    display: false
                )
            } else {
                window.center()
            }
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        mainWindow = window

        // Closing the window must not leave SSH connections running in the
        // background (the app stays alive for the Quake terminal).
        window.delegate = self

        installToolbar(on: window)
        startToolbarKeepAlive(on: window)
    }

    // MARK: - Window Closing

    /// From macOS 26 the line under the toolbar ignores `titlebarSeparatorStyle`.
    /// A transparent titlebar is what removes it, including the extra rule that
    /// appears over the inspector once that pane opens.
    func applyTitlebarPolicy(isFullScreen: Bool? = nil) {
        guard let window = mainWindow else { return }
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
        hidePrivateTitlebarSeparator(in: window)
        // The separator view is inserted after the toolbar finishes laying out.
        Task { @MainActor in
            self.hidePrivateTitlebarSeparator(in: window)
        }
        let fullScreen = isFullScreen ?? window.styleMask.contains(.fullScreen)
        let toolbarVisible = window.toolbar?.isVisible ?? false
        // In full screen with the toolbar hidden, the bar that slides down needs
        // its own background. Everywhere else the transparent bar is the one
        // that does not draw a rule.
        window.titlebarAppearsTransparent = fullScreen ? toolbarVisible : true
        installGlassBackdrop(in: window, fullScreen: fullScreen)
        if window.titlebarAppearsTransparent {
            matchTitlebarToPage(in: window)
        }
    }

    /// The gutter and the toolbar sample the desktop through one glass view.
    /// A clear window with nothing behind it is a hole. A painted fill is a
    /// second color. Regular glass is the material between those.
    private func installGlassBackdrop(in window: NSWindow, fullScreen: Bool) {
        guard let content = window.contentView, let theme = content.superview else { return }
        let backdrop: NSView
        if let glassBackdrop {
            backdrop = glassBackdrop
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: theme.bounds)
            glass.style = .regular
            glass.cornerRadius = 0
            glass.autoresizingMask = [.width, .height]
            let fill = NSView(frame: glass.bounds)
            fill.autoresizingMask = [.width, .height]
            glass.contentView = fill
            theme.addSubview(glass, positioned: .below, relativeTo: content)
            glassBackdrop = glass
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: theme.bounds)
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            effect.autoresizingMask = [.width, .height]
            theme.addSubview(effect, positioned: .below, relativeTo: content)
            glassBackdrop = effect
            backdrop = effect
        }
        backdrop.frame = theme.bounds
        if fullScreen {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            backdrop.isHidden = true
        } else {
            window.isOpaque = false
            window.backgroundColor = .clear
            backdrop.isHidden = false
        }
    }

    /// The unified toolbar paints its own material on top of the glass. Take
    /// that off so the bar shows the same glass as the gutter.
    func matchTitlebarToPage(in window: NSWindow) {
        guard window.titlebarAppearsTransparent, !matchingTitlebar else { return }
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        matchingTitlebar = true
        defer { matchingTitlebar = false }
        if let theme = window.contentView?.superview {
            for subview in theme.subviews where subview is NSVisualEffectView
                && subview !== glassBackdrop && !subview.isHidden {
                subview.isHidden = true
            }
        }
        let root = titlebar.superview ?? titlebar
        func walk(_ view: NSView) {
            let name = NSStringFromClass(type(of: view))
            let isChromeFill = name.contains("Backdrop") || name.contains("Decoration")
                || name.contains("TitlebarSeparator") || name.contains("ToolbarSeparator")
            if isChromeFill, !view.isHidden {
                view.isHidden = true
                view.alphaValue = 0
            }
            if let effect = view as? NSVisualEffectView {
                effect.wantsLayer = true
                if effect.layer?.backgroundFilters?.isEmpty == false {
                    effect.layer?.backgroundFilters = []
                }
                if effect.layer?.filters?.isEmpty == false {
                    effect.layer?.filters = []
                }
                if effect.layer?.compositingFilter != nil {
                    effect.layer?.compositingFilter = nil
                }
                effect.layer?.backgroundColor = NSColor.clear.cgColor
                effect.layer?.isOpaque = false
            }
            if name.contains("Titlebar") {
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.clear.cgColor
                view.layer?.isOpaque = false
            }
            view.subviews.forEach(walk)
        }
        walk(root)
    }

    /// macOS 26 still inserts a private separator under the toolbar after
    /// `titlebarSeparatorStyle` is set. It is the line between the toolbar and
    /// the page. Hide that view; leave split dividers alone.
    private func hidePrivateTitlebarSeparator(in window: NSWindow) {
        guard let frame = window.contentView?.superview else { return }
        func walk(_ view: NSView) {
            let name = NSStringFromClass(type(of: view))
            if name.contains("TitlebarSeparator") || name.contains("ToolbarSeparator") {
                view.isHidden = true
                view.alphaValue = 0
            }
            view.subviews.forEach(walk)
        }
        walk(frame)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        applyTitlebarPolicy(isFullScreen: true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        applyTitlebarPolicy(isFullScreen: false)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === mainWindow else { return }
        Task { @MainActor [weak self] in
            await self?.sessionManager?.disconnectAllTabs()
        }
    }

    // MARK: - Toolbar

    private func installToolbar(on window: NSWindow) {
        // Older builds shipped a stale autosaved toolbar layout (before the
        // server-resource items existed). Clear it once, then let AppKit
        // persist user customizations from now on.
        // v3 adds the inspector-tracking separator. A saved layout from before
        // that item exists keeps the trailing buttons pinned to the window edge,
        // so they sit on top of the inspector instead of moving left with it.
        if !UserDefaults.standard.bool(forKey: "toolbar_config_migrated_v3") {
            UserDefaults.standard.removeObject(
                forKey: "NSToolbar Configuration com.bonk.mainWindowToolbar"
            )
            UserDefaults.standard.set(true, forKey: "toolbar_config_migrated_v3")
        }

        let toolbar = NSToolbar(identifier: "com.bonk.mainWindowToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        self.toolbar = toolbar
        window.toolbar = toolbar
        applyTitlebarPolicy()
        window.toolbar?.validateVisibleItems()
        Log.ui.info("Main window toolbar installed: \(toolbar.identifier, privacy: .public), items=\(toolbar.items.count, privacy: .public)")
    }

    /// If anything ever swaps `window.toolbar` (SwiftUI's hosted toolbar
    /// bridge, or a stale autosave), put ours back on the next runloop turn.
    private func startToolbarKeepAlive(on window: NSWindow) {
        toolbarObservation = window.observe(\.toolbar, options: [.new]) { [weak self] _, change in
            // KVO fires on the main thread; observe() annotates the closure
            // as @Sendable so hop back explicitly.
            Task { @MainActor [weak self] in
                guard let self,
                      let current = change.newValue as? NSToolbar,
                      current !== self.toolbar else { return }
                Log.ui.warning("Window toolbar was replaced (delegate=\(String(describing: current.delegate.map { String(describing: type(of: $0)) }), privacy: .public)); restoring ours")
                guard let window = self.mainWindow, window.toolbar !== self.toolbar else { return }
                window.toolbar = self.toolbar
                self.applyTitlebarPolicy()
                window.toolbar?.validateVisibleItems()
            }
        }
    }

    // MARK: - Theme

    private func applyTheme() {
        let themeID = UserDefaults.standard.string(forKey: "terminalThemeID") ?? "system"
        if themeID == "system" {
            ThemeManager.apply("system")
        } else {
            let isDark = UserDefaults.standard.bool(forKey: "terminalThemeIsDark")
            ThemeManager.apply(isDark ? "dark" : "light")
        }
        TerminalThemeManager.shared.initializeIfNeeded()
    }

    // MARK: - Window Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        // Keep running with the Quake terminal (global hotkey) available.
        false
    }

    func applicationWillTerminate(_: Notification) {
        // Record the host count on a signal that actually fires. This marker
        // is the only thing distinguishing "the user deleted everything" from
        // "the store was destroyed", so it has to be trustworthy: the previous
        // wiring sat in the Settings scene's scenePhase, which on macOS is
        // AppKit-owned and effectively never reaches .background.
        StoreHealthGuard.recordHostCount(currentHostCount())
        // Kill every bonk-ssh child so no PTY-holding process survives the
        // app (a plain app exit leaves the ssh children behind until the
        // NEXT launch's cleanup runs).
        #if os(macOS)
            OpenSSHBackend.cleanupOrphanedMuxes()
        #endif
        // Snapshot open tabs for post-update restore (consumed only when
        // the Sparkle delegate flagged this terminate as an update relaunch).
        if let sm = sessionManager {
            SessionRestore.snapshot(tabs: sm.tabs, activeTabID: sm.activeTabID)
        }
    }

    private func currentHostCount() -> Int {
        let context = ModelContext(BonkApp.sharedModelContainer)
        return (try? context.fetchCount(FetchDescriptor<HostItem>())) ?? 0
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // MARK: - URL Handling (bonk://connect?host=<uuid>)

    /// Entry point for the bonk:// URL scheme — used by ConnectHostIntent
    /// (Siri / Spotlight / Shortcuts) and any future deep link. Additive:
    /// unknown hosts/paths are ignored, existing flow is untouched.
    func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "bonk",
              url.host == "connect",
              let idString = URLComponents(url: url, resolvingAgainstBaseURL: false)?
              .queryItems?.first(where: { $0.name == "host" })?.value,
              let id = UUID(uuidString: idString) else { return }

        Task { @MainActor [weak self] in
            guard let self, let sessionManager = self.sessionManager else { return }
            // Prefer the UI's context; fall back to a fresh one (e.g. cold
            // launch straight into a connect URL before any view appears).
            let context = sessionManager.modelContext ?? ModelContext(BonkApp.sharedModelContainer)
            let descriptor = FetchDescriptor<HostItem>(predicate: #Predicate { $0.id == id })
            guard let host = try? context.fetch(descriptor).first else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.mainWindow?.makeKeyAndOrderFront(nil)
            sessionManager.openHost(host)
        }
    }
}
