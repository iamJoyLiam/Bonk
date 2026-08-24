//
//  QuakeFocusManager.swift
//  Bonk
//
//  Focus management for Quake window.
//

import AppKit
import os.log

// MARK: - Esc Behavior

/// Behavior when ESC is pressed in Quake window.
enum EscBehavior: String, Sendable, CaseIterable {
    case always = "always"
    case never = "never"
    case onlyWhenNoAlternateScreen = "alternate_screen"

    var displayName: String {
        switch self {
        case .always: "Always Hide"
        case .never: "Never Hide"
        case .onlyWhenNoAlternateScreen: "Only When No Alternate Screen"
        }
    }
}

// MARK: - Quake Focus Manager

/// Manages focus behavior for Quake window.
@MainActor
final class QuakeFocusManager {
    private let logger = Logger(subsystem: "com.bonk", category: "QuakeFocus")

    /// Window to monitor.
    private weak var window: NSPanel?

    /// Whether auto-hide on focus loss is enabled.
    var autoHideOnFocusLoss: Bool = true

    /// Callback when window should hide due to focus loss.
    var onFocusLost: (() -> Void)?

    /// Observation tokens.
    private var observations: [NSObjectProtocol] = []

    // MARK: - Public API

    /// Start monitoring focus changes for a window.
    func startMonitoring(window: NSPanel) {
        self.window = window

        // Observe window resign key status
        let resignObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleFocusLost()
            }
        }
        observations.append(resignObservation)

        // Observe window become key status (for re-focus)
        let keyObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleFocusGained()
            }
        }
        observations.append(keyObservation)

        // Observe app activation (clicking on other apps)
        let activationObservation = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleFocusLost()
            }
        }
        observations.append(activationObservation)

        logger.info("Started monitoring focus")
    }

    /// Stop monitoring focus changes.
    func stopMonitoring() {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
        observations.removeAll()
        window = nil
        logger.info("Stopped monitoring focus")
    }

    // MARK: - Focus Handling

    private func handleFocusLost() {
        guard autoHideOnFocusLoss, let window, window.isVisible else { return }
        logger.debug("Focus lost, triggering hide")
        onFocusLost?()
    }

    private func handleFocusGained() {
        logger.debug("Focus gained")
        // No action needed, just logging
    }

    // MARK: - Alternate Screen Detection

    /// Provider that returns true when any visible terminal is in alternate screen (vim/less).
    /// Set by `QuakeController` to query `TerminalViewCache` / SwiftTerm state.
    var alternateScreenProvider: (@MainActor () -> Bool)?

    /// Check if the terminal is currently in alternate screen mode (vim, less, etc.).
    @MainActor
    func isInAlternateScreen() -> Bool {
        if let provider = alternateScreenProvider { return provider() }
        return false
    }
}
