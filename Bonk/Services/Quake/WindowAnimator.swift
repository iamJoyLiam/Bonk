//
//  WindowAnimator.swift
//  Bonk
//
//  Animation manager for Quake window show/hide.
//

import AppKit
import os.log

// MARK: - Animation Duration

/// Animation duration configuration.
struct AnimationDuration: Sendable {
    let show: TimeInterval
    let hide: TimeInterval

    static let `default` = AnimationDuration(show: 0.18, hide: 0.15)
    static let fast = AnimationDuration(show: 0.12, hide: 0.10)
    static let slow = AnimationDuration(show: 0.30, hide: 0.25)
}

// MARK: - Window Animator

/// Manages window animations for Quake panel.
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
            y: frame.origin.y + frame.height,
            width: frame.width,
            height: frame.height
        )

        panel.setFrame(startFrame, display: false)
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration.show
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true

            panel.setFrame(frame, display: true, animate: true)
        } completionHandler: { [weak self] in
            self?.isAnimating = false
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
            y: currentFrame.origin.y + currentFrame.height,
            width: currentFrame.width,
            height: currentFrame.height
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration.hide
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true

            panel.setFrame(endFrame, display: true, animate: true)
        } completionHandler: { [weak self] in
            self?.isAnimating = false
            panel.orderOut(nil)
            completion?()
        }

        logger.debug("Animating hide")
    }

    /// Instantly show window without animation.
    func showInstant(panel: NSPanel, frame: CGRect) {
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
    }

    /// Instantly hide window without animation.
    func hideInstant(panel: NSPanel) {
        panel.orderOut(nil)
    }
}
