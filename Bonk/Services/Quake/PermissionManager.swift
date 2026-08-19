//
//  PermissionManager.swift
//  Bonk
//
//  Manages Accessibility permissions for global hotkey support.
//

import AppKit
import os.log

// MARK: - Permission Manager

/// Manages Accessibility permissions required for global hotkeys.
@Observable
final class PermissionManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.bonk", category: "Permission")

    /// Whether Accessibility permission is granted.
    private(set) var isAccessibilityGranted = false

    /// Notification when permission state changes.
    var onPermissionChanged: (@Sendable (Bool) -> Void)?

    init() {
        checkAccessibility()
        startObservingPermissionChanges()
    }

    // MARK: - Public API

    /// Check if Accessibility permission is currently granted.
    @discardableResult
    func checkAccessibility() -> Bool {
        let granted = AXIsProcessTrusted()
        if granted != isAccessibilityGranted {
            isAccessibilityGranted = granted
            logger.info("Accessibility permission: \(granted ? "granted" : "denied")")
        }
        return granted
    }

    /// Request Accessibility permission (opens System Settings).
    /// This will show a dialog explaining why permission is needed.
    func requestAccessibility() {
        // Use AXIsProcessTrusted() which shows the system permission dialog
        // The dialog explains that the app needs Accessibility access
        let granted = AXIsProcessTrusted()
        isAccessibilityGranted = granted
        logger.info("Accessibility permission requested: \(granted ? "granted" : "denied")")

        if !granted {
            // Open System Settings to Accessibility section
            openAccessibilitySettings()
        }
    }

    /// Open System Settings to Accessibility section.
    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Permission Change Observation

    private var permissionObservation: NSObjectProtocol?

    private func startObservingPermissionChanges() {
        // Listen for app activation changes (user may grant permission in System Settings)
        permissionObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Re-check when active app changes (observer fires on main queue).
            let pm = self
            MainActor.assumeIsolated {
                pm?.checkAccessibility()
                pm?.onPermissionChanged?(pm?.isAccessibilityGranted ?? false)
            }
        }
    }

    deinit {
        if let observer = permissionObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
