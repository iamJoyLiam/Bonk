//
//  QuakeController.swift
//  Bonk
//
//  Core controller coordinating Quake terminal components.
//

import AppKit
import os.log
import SwiftData

// MARK: - Quake Controller

/// Core controller for Quake dropdown terminal.
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

    /// Whether Quake is currently visible.
    var isVisible: Bool { windowController?.isVisible ?? false }

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
                self?.hide()
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

    /// Toggle Quake window visibility.
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

        guard let windowController else {
            logger.error("Window controller not initialized")
            return
        }

        if windowController.isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Show Quake window.
    func show() {
        guard let windowController else { return }

        windowController.show(
            heightRatio: configuration.heightRatio,
            widthRatio: configuration.widthRatio
        )

        // Focus the content view after show animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.animationDuration.show) {
            windowController.focusContentView()
        }
    }

    /// Hide Quake window.
    func hide() {
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
        if isVisible {
            windowController?.updateFrame(
                heightRatio: newConfig.heightRatio,
                widthRatio: newConfig.widthRatio
            )
        }

        logger.info("Configuration updated")
    }

    // MARK: - Cleanup

    func cleanup() {
        hotkeyService.unregister()
        focusManager.stopMonitoring()
        windowController = nil
        logger.info("QuakeController cleaned up")
    }
}
