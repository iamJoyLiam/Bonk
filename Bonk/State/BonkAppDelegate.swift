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
        if !UserDefaults.standard.bool(forKey: "toolbar_config_migrated_v2") {
            UserDefaults.standard.removeObject(
                forKey: "NSToolbar Configuration com.bonk.mainWindowToolbar"
            )
            UserDefaults.standard.set(true, forKey: "toolbar_config_migrated_v2")
        }

        let toolbar = NSToolbar(identifier: "com.bonk.mainWindowToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar
        window.toolbar = toolbar
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
