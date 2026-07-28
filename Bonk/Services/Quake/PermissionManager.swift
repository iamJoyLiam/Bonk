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
final class PermissionManager {
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
    func requestAccessibility() {
        let granted = AXIsProcessTrustedWithOptions(nil)
        isAccessibilityGranted = granted
        logger.info("Accessibility permission requested: \(granted ? "granted" : "denied")")
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
            // Re-check when active app changes
            self?.checkAccessibility()
            self?.onPermissionChanged?(self?.isAccessibilityGranted ?? false)
        }
    }

    deinit {
        if let observer = permissionObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
