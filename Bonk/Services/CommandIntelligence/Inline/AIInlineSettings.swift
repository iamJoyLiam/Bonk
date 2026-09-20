//
//  AIInlineSettings.swift
//  Bonk
//
//  In-memory snapshot of AI toggles for the keystroke hot path.
//  processKeyEvent and friends read memory instead of querying UserDefaults
//  synchronously per key; the snapshot refreshes via
//  UserDefaults.didChangeNotification when settings change.
//

import Foundation

/// AI toggles as seen by the hot path (semantics match the original
/// UserDefaults reads).
struct AISettingsSnapshot: Sendable {
    /// Defaults to false, matching bool(forKey:) with no key set
    /// (AI must be explicitly enabled).
    let aiEnabled: Bool
    /// Defaults to false, matching bool(forKey:) with no key set.
    let inlineSuggestionsEnabled: Bool
    /// Defaults to true, matching object(forKey:) as? Bool ?? true.
    let candidatePopupEnabled: Bool
}

/// Hot-path settings cache: resident singleton, reads are in-memory,
/// refresh happens on settings change.
final class AIInlineSettings: @unchecked Sendable {
    static let shared = AIInlineSettings()

    /// Hot-path entry point: lock-guarded internally, callable from any thread.
    static var current: AISettingsSnapshot {
        let shared = AIInlineSettings.shared
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.cached
    }

    private let lock = NSLock()
    private var cached: AISettingsSnapshot
    private var observer: (any NSObjectProtocol)?

    private init() {
        cached = Self.read()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let fresh = Self.read()
        lock.lock()
        cached = fresh
        lock.unlock()
    }

    private static func read() -> AISettingsSnapshot {
        let defaults = UserDefaults.standard
        return AISettingsSnapshot(
            aiEnabled: defaults.bool(forKey: "ai_enabled"),
            inlineSuggestionsEnabled: defaults.bool(forKey: "ai_inline_suggestions"),
            candidatePopupEnabled: defaults.object(forKey: "ai_inline_candidate_popup") as? Bool ?? true
        )
    }
}
