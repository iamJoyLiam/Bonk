//
//  QuakeController.swift
//  Bonk
//
//  Core controller coordinating terminal presentation modes.
//  Manages transitions between embedded ↔ quake modes.
//  The terminal doesn't know its mode - only this controller manages transitions.
//

import AppKit
import os.log
import SwiftData

// MARK: - Quake Controller

/// Core controller for terminal presentation modes.
/// Coordinates hotkey, window, animation, and focus.
@Observable
@MainActor
final class QuakeController {
    private let logger = Logger(subsystem: "com.bonk", category: "Quake")

    // MARK: - Components

    /// Permission manager for Accessibility.
    let permissionManager = PermissionManager()

    /// Hotkey service.
    private var hotkeyService: GlobalHotkeyService

    /// Window controller.
    private var windowController: QuakeWindowController?

    /// Focus manager.
    private let focusManager = QuakeFocusManager()

    // MARK: - State

    /// Current configuration.
    var configuration: QuakeConfiguration

    /// Model container for SwiftData access.
    var modelContainer: ModelContainer?

    /// Current presentation mode.
    private(set) var currentMode: PresentationMode = .embedded

    /// Whether Quake is currently visible.
    var isVisible: Bool { currentMode == .quake }

    // MARK: - Initialization

    init(configuration: QuakeConfiguration = .init()) {
        self.configuration = configuration
        self.hotkeyService = CarbonHotkeyService()
    }

    // MARK: - Setup

    /// Setup Quake with content view.
    func setup(contentView: NSView) {
        // Create window controller
        windowController = QuakeWindowController(contentView: contentView)

        // Setup focus manager
        if let panel = windowController?.panel {
            focusManager.autoHideOnFocusLoss = configuration.autoHideOnFocusLoss
            focusManager.onFocusLost = { [weak self] in
                Task { @MainActor in
                    self?.transitionTo(.embedded)
                }
            }
            focusManager.startMonitoring(window: panel)
        }

        // Setup hotkey
        setupHotkey()

        // Setup permission monitoring
        permissionManager.onPermissionChanged = { [weak self] granted in
            Task { @MainActor in
                if granted {
                    self?.setupHotkey()
                }
            }
        }

        logger.info("QuakeController setup complete")
    }

    // MARK: - Hotkey Setup

    private func setupHotkey() {
        guard permissionManager.isAccessibilityGranted else {
            logger.warning("Accessibility permission not granted, skipping hotkey setup")
            return
        }

        hotkeyService.onPress = { [weak self] in
            self?.toggle()
        }
        do {
            try hotkeyService.register(shortcut: configuration.shortcut)
            logger.info("Hotkey registered: \(self.configuration.shortcut.description)")
        } catch {
            logger.error("Failed to register hotkey: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    /// Toggle between embedded and quake modes.
    func toggle() {
        guard configuration.enabled else {
            logger.warning("Quake is disabled")
            return
        }

        guard permissionManager.isAccessibilityGranted else {
            logger.warning("Accessibility permission not granted")
            permissionManager.requestAccessibility()
            return
        }

        if currentMode == .quake {
            transitionTo(.embedded)
        } else {
            transitionTo(.quake)
        }
    }

    /// Transition to a specific presentation mode.
    func transitionTo(_ mode: PresentationMode) {
        guard currentMode != mode else {
            logger.debug("Already in mode \(String(describing: mode))")
            return
        }

        let previousMode = currentMode
        currentMode = mode

        switch mode {
        case .quake:
            showQuakeWindow()
        case .embedded:
            hideQuakeWindow()
        }

        logger.info("Transitioned from \(String(describing: previousMode)) to \(String(describing: mode))")
    }

    // MARK: - Window Management

    private func showQuakeWindow() {
        guard let windowController else { return }

        // First activate the app
        NSApp.activate(ignoringOtherApps: true)

        windowController.show(
            heightRatio: configuration.heightRatio,
            widthRatio: configuration.widthRatio
        )

        // Focus the content view after show animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.animationDuration.show + 0.1) {
            // Double activate to ensure focus
            NSApp.activate(ignoringOtherApps: true)
            windowController.panel.makeKey()

            // Find and focus terminal view
            NotificationCenter.default.post(name: .focusTerminal, object: nil)

            // Also try to directly make first responder
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                windowController.panel.makeKey()
            }
        }
    }

    private func hideQuakeWindow() {
        windowController?.hide()
    }

    // MARK: - Configuration Update

    /// Update configuration and reapply settings.
    func updateConfiguration(_ newConfig: QuakeConfiguration) {
        configuration = newConfig
        configuration.save()

        // Re-register hotkey
        hotkeyService.unregister()
        setupHotkey()

        // Update focus manager
        focusManager.autoHideOnFocusLoss = newConfig.autoHideOnFocusLoss

        // Update window if visible
        if currentMode == .quake {
            windowController?.updateFrame(
                heightRatio: newConfig.heightRatio,
                widthRatio: newConfig.widthRatio
            )
        }

        logger.info("Configuration updated")
    }
}
