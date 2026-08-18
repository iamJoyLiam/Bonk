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
final class BonkAppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var toolbarDelegate: BonkToolbarDelegate?
    private var toolbar: NSToolbar?
    private var toolbarObservation: NSKeyValueObservation?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashReporter.install()
        applyTheme()

        let i18n = I18n.shared
        let workspace = WorkspaceManager()
        let sessionManager = SessionManager()
        let coordinator = ToolbarCoordinator(
            workspace: workspace,
            sessionManager: sessionManager,
            i18n: i18n
        )
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

        let splitVC = MainSplitViewController(
            workspace: workspace,
            sessionManager: sessionManager,
            i18n: i18n,
            coordinator: coordinator,
            modelContainer: BonkApp.sharedModelContainer
        )
        window.contentViewController = splitVC
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window

        installToolbar(on: window)
        startToolbarKeepAlive(on: window)
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
            guard let self,
                  let current = change.newValue as? NSToolbar,
                  current !== self.toolbar
            else { return }
            Log.ui.warning("Window toolbar was replaced (delegate=\(String(describing: current.delegate.map { String(describing: type(of: $0)) }), privacy: .public)); restoring ours")
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.mainWindow, window.toolbar !== self.toolbar else { return }
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
