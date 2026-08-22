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
    static weak var shared: BonkAppDelegate?
    private var mainWindow: NSWindow?
    private var toolbarDelegate: BonkToolbarDelegate?
    private var toolbar: NSToolbar?
    private var toolbarObservation: NSKeyValueObservation?
    var sessionManager: SessionManager?
    var workspace: WorkspaceManager?
    var coordinator: ToolbarCoordinator?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        window.title = "Bonk"
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
        toolbarObservation = window.observe(\.toolbar, options: [.new]) { [weak self] window, change in
            // KVO fires on the main thread; observe() annotates the closure
            // as @Sendable so hop back explicitly.
            Task { @MainActor [weak self] in
                guard let self,
                      let current = change.newValue as? NSToolbar,
                      current !== self.toolbar
                else { return }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running with the Quake terminal (global hotkey) available.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Kill every bonk-ssh child so no PTY-holding process survives the
        // app (a plain app exit leaves the ssh children behind until the
        // NEXT launch's cleanup runs).
        #if os(macOS)
            OpenSSHBackend.cleanupOrphanedMuxes()
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
