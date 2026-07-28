//
//  QuakeWindowController.swift
//  Bonk
//
//  Window controller for Quake terminal (composition pattern).
//

import AppKit
import os.log

// MARK: - Quake Window Controller

/// Manages the Quake-style dropdown terminal window.
/// Uses composition (holds NSPanel) instead of inheritance.
@MainActor
final class QuakeWindowController {
    private let logger = Logger(subsystem: "com.bonk", category: "QuakeWindow")

    /// The managed NSPanel.
    let panel: NSPanel

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

        // Create panel - clean borderless style, no title bar
        panel = NSPanel(
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

        // macOS 26 style: floating level for Quake
        panel.level = .floating

        // Visual style
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // Behavior
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true

        // Title bar
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.styleMask.insert(.fullSizeContentView)

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

    /// Toggle window visibility.
    func toggle(heightRatio: CGFloat = 0.5, widthRatio: CGFloat = 1.0) {
        if isVisible {
            hide()
        } else {
            show(heightRatio: heightRatio, widthRatio: widthRatio)
        }
    }

    /// Show without animation (for initial setup).
    func showInstant(heightRatio: CGFloat = 0.5, widthRatio: CGFloat = 1.0) {
        let frame = ScreenManager.quakeFrame(heightRatio: heightRatio, widthRatio: widthRatio)
        animator.showInstant(panel: panel, frame: frame)
    }

    /// Update window frame.
    func updateFrame(heightRatio: CGFloat = 0.5, widthRatio: CGFloat = 1.0) {
        let frame = ScreenManager.quakeFrame(heightRatio: heightRatio, widthRatio: widthRatio)
        panel.setFrame(frame, display: true)
    }

    /// Make the window key (for keyboard input).
    func makeKey() {
        panel.makeKeyAndOrderFront(nil)
    }

    /// Focus the first responder in the content view.
    func focusContentView() {
        panel.makeFirstResponder(contentViewController.view)
    }
}
