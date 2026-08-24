//
//  QuakeWindowController.swift
//  Bonk
//
//  Window controller for Quake terminal (composition pattern).
//

import AppKit
import os.log
import SwiftUI

// MARK: - Quake Panel

/// Custom NSPanel that can become key window even when borderless.
class QuakePanel: NSPanel {
    /// Handler for ESC key; return true if handled (swallow), false to pass through.
    var escHandler: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let handler = escHandler, handler() { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let handler = escHandler, handler() { return }
        super.cancelOperation(sender)
    }
}

// MARK: - Quake Window Controller

/// Manages the Quake-style dropdown terminal window.
/// Uses composition (holds NSPanel) instead of inheritance.
@MainActor
final class QuakeWindowController {
    private let logger = Logger(subsystem: "com.bonk", category: "QuakeWindow")

    /// The managed panel (custom QuakePanel subclass).
    let panel: QuakePanel

    /// Window animator for show/hide animations.
    let animator = WindowAnimator()

    /// Content view controller.
    private let contentViewController: NSViewController

    /// Whether the window is currently visible.
    var isVisible: Bool { panel.isVisible }

    // MARK: - Initialization

    init(contentView: NSView) {
        // Create hosting view controller
        contentViewController = NSViewController()
        contentViewController.view = contentView

        // Create panel - use custom QuakePanel subclass for focus support
        panel = QuakePanel(
            contentRect: .zero,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: true
        )

        setupPanel()
        setupAnimations()
    }

    // MARK: - Setup

    private func setupPanel() {
        panel.contentViewController = contentViewController

        // Floating level for always-on-top
        panel.level = .floating

        // Visual style - hide title bar but keep focus support
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.styleMask.insert(.fullSizeContentView)

        // Behavior
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .utilityWindow

        // Set initial frame to hidden position
        let hiddenFrame = ScreenManager.hiddenFrame()
        panel.setFrame(hiddenFrame, display: false)
    }

    private func setupAnimations() {
        // No additional setup needed
    }

    // MARK: - Public API

    /// Show the window with animation.
    func show(heightRatio: CGFloat = 0.5, widthRatio: CGFloat = 1.0, completion: (() -> Void)? = nil) {
        let frame = ScreenManager.quakeFrame(heightRatio: heightRatio, widthRatio: widthRatio)
        animator.show(panel: panel, frame: frame, completion: completion)
        logger.info("Showing Quake window")
    }

    /// Hide the window with animation.
    func hide(completion: (() -> Void)? = nil) {
        animator.hide(panel: panel, completion: completion)
        logger.info("Hiding Quake window")
    }

    /// Update window frame.
    func updateFrame(heightRatio: CGFloat = 0.5, widthRatio: CGFloat = 1.0) {
        let frame = ScreenManager.quakeFrame(heightRatio: heightRatio, widthRatio: widthRatio)
        panel.setFrame(frame, display: true)
    }
}
