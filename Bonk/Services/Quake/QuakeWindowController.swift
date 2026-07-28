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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
        // Force focus to content view
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    /// Focus the first responder in the content view.
    func focusContentView() {
        // Find and focus the terminal view
        if let terminalView = findTerminalView(in: contentViewController.view) {
            panel.makeFirstResponder(terminalView)
        } else {
            panel.makeFirstResponder(contentViewController.view)
        }
    }

    /// Recursively find a SwiftTerm TerminalView in the view hierarchy.
    private func findTerminalView(in view: NSView) -> NSView? {
        // Check if this is a TerminalView
        if NSStringFromClass(type(of: view)).contains("TerminalView") {
            return view
        }
        // Check subviews
        for subview in view.subviews {
            if let found = findTerminalView(in: subview) {
                return found
            }
        }
        return nil
    }
}
