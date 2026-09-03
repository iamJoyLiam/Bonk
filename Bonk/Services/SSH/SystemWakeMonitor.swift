// SystemWakeMonitor.swift
// Bonk
//
// Independent system wake/sleep monitor per P0 spec.
// Produces SystemWakeEvent stream; SSHNetworkService must not directly observe NSWorkspace.
// Wake is explicit recovery trigger, not Task.sleep compensation.

#if os(macOS)
import AppKit
import Foundation
import os
import os.log

/// Unified wake/sleep/app events for SSH recovery.
enum SystemWakeEvent: Sendable, Equatable {
    case systemSleep(atValue: Date)
    case systemWake(atValue: Date, sleepDuration: TimeInterval?)
    case appDidBecomeActive(atValue: Date)
    case appWillResignActive(atValue: Date)
}

/// Independent monitor that publishes SystemWakeEvent.
/// Single responsibility: translate macOS notifications into typed events.
final class SystemWakeMonitor: NSObject, @unchecked Sendable {
    static let shared = SystemWakeMonitor()

    private let stream: AsyncStream<SystemWakeEvent>
    private let continuation: AsyncStream<SystemWakeEvent>.Continuation
    private let stateBox: OSAllocatedUnfairLock<State>

    private struct State {
        var sleepAt: Date?
    }

    var events: AsyncStream<SystemWakeEvent> { stream }

    private override init() {
        var createdContinuation: AsyncStream<SystemWakeEvent>.Continuation!
        stream = AsyncStream<SystemWakeEvent>(bufferingPolicy: .bufferingNewest(16)) { continuation in
            createdContinuation = continuation
        }
        continuation = createdContinuation
        stateBox = OSAllocatedUnfairLock(initialState: State())
        super.init()
        // Observe on MainActor (AppKit notifications are main-thread)
        Task { @MainActor [weak self] in
            self?.installObservers()
        }
    }

    @MainActor
    private func installObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default

        // System sleep / wake (screens + workspace)
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSystemWillSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        // Additional: system will sleep
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSystemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        defaultCenter.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        defaultCenter.addObserver(
            self,
            selector: #selector(handleAppWillResignActive(_:)),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )

        Log.ssh.info("[WAKE] SystemWakeMonitor installed")
    }

    @objc
    private func handleSystemWillSleep(_ notification: Notification) {
        let now = Date()
        stateBox.withLock { $0.sleepAt = now }
        continuation.yield(.systemSleep(atValue: now))
        Log.ssh.info("[WAKE] systemSleep atValue \(now, privacy: .public)")
    }

    @objc
    private func handleSystemDidWake(_ notification: Notification) {
        let now = Date()
        let duration = stateBox.withLock { state -> TimeInterval? in
            guard let sleepAt = state.sleepAt else { return nil }
            state.sleepAt = nil
            return now.timeIntervalSince(sleepAt)
        }
        continuation.yield(.systemWake(atValue: now, sleepDuration: duration))
        if let duration {
            Log.ssh.info("[WAKE] systemWake atValue \(now, privacy: .public) sleepDuration=\(duration, privacy: .public)s")
        } else {
            Log.ssh.info("[WAKE] systemWake atValue \(now, privacy: .public) sleepDuration=unknown")
        }
    }

    @objc
    private func handleAppDidBecomeActive(_ notification: Notification) {
        let now = Date()
        continuation.yield(.appDidBecomeActive(atValue: now))
        Log.ssh.debug("[WAKE] appDidBecomeActive atValue \(now, privacy: .public)")
    }

    @objc
    private func handleAppWillResignActive(_ notification: Notification) {
        let now = Date()
        continuation.yield(.appWillResignActive(atValue: now))
        Log.ssh.debug("[WAKE] appWillResignActive atValue \(now, privacy: .public)")
    }
}

#endif
