//
//  WindowAnimator.swift
//  Bonk
//
//  Animation manager for Quake window show/hide.
//  macOS 26 style: smooth spring animations.
//

import AppKit
import os.log

// MARK: - Animation Duration

/// Animation duration configuration.
struct AnimationDuration: Sendable {
    let show: TimeInterval
    let hide: TimeInterval

    static let `default` = AnimationDuration(show: 0.25, hide: 0.2)
    static let fast = AnimationDuration(show: 0.15, hide: 0.12)
    static let slow = AnimationDuration(show: 0.35, hide: 0.3)
}

// MARK: - Window Animator

/// Manages window animations for Quake panel.
/// macOS 26 style: smooth spring-like animations.
@MainActor
final class WindowAnimator {
    private let logger = Logger(subsystem: "com.bonk", category: "QuakeAnim")

    /// Animation duration configuration.
    var duration: AnimationDuration = .default

    /// Whether an animation is currently in progress.
    private(set) var isAnimating = false

    // MARK: - Public API

    /// Show window with slide-in animation from top of screen.
    func show(panel: NSPanel, frame: CGRect, completion: (() -> Void)? = nil) {
        guard !isAnimating else { return }
        isAnimating = true

        // Start from above screen
        let startFrame = CGRect(
            x: frame.origin.x,
            y: frame.origin.y + frame.height * 0.3,
            width: frame.width,
            height: frame.height * 0.95
        )

        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0.0
        panel.orderFront(nil)

        // macOS 26 style: smooth spring animation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration.show
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.0, 1.0)
            context.allowsImplicitAnimation = true

            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1.0
        } completionHandler: { [weak self] in
            self?.isAnimating = false

            // Force activate app and make panel key for keyboard input
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                panel.makeKey()
                panel.makeFirstResponder(nil) // Let first responder chain work
            }

            completion?()
        }

        logger.debug("Animating show")
    }

    /// Hide window with slide-out animation to top of screen.
    func hide(panel: NSPanel, completion: (() -> Void)? = nil) {
        guard !isAnimating else { return }
        isAnimating = true

        let currentFrame = panel.frame
        let endFrame = CGRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + currentFrame.height * 0.3,
            width: currentFrame.width,
            height: currentFrame.height * 0.95
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration.hide
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0) // Smooth ease-in
            context.allowsImplicitAnimation = true

            // Animate position, size, and opacity together
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            self?.isAnimating = false
            panel.orderOut(nil)
            panel.alphaValue = 1.0 // Reset for next show
            completion?()
        }

        logger.debug("Animating hide")
    }
}
