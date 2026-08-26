//
//  TriggerManager.swift
//  Bonk
//
//  Evaluates TriggerRule against terminal output and dispatches actions.
//

import Foundation
import os.log
import SwiftData
import UserNotifications

@MainActor
@Observable
final class TriggerManager {
    static let shared = TriggerManager()
    private let logger = Logger(subsystem: "com.bonk", category: "Trigger")
    private var modelContext: ModelContext?
    private var lastFire: [String: Date] = [:] // ruleID+paneID -> date
    private let throttleInterval: TimeInterval = 1.0
    /// Cached enabled rules — refreshed on demand, not per-chunk fetch.
    private var cachedRules: [TriggerRule] = []
    private var cachedRegex: [UUID: NSRegularExpression] = [:]
    private var lastCacheRefresh: Date = .distantPast
    private let cacheTTL: TimeInterval = 1.0

    private init() {}

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        refreshCache(force: true)
    }

    /// Force refresh after rule CRUD.
    func refreshCache(force: Bool = false) {
        guard let ctx = modelContext else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastCacheRefresh) >= cacheTTL else { return }
        lastCacheRefresh = now
        let descriptor = FetchDescriptor<TriggerRule>(predicate: #Predicate { $0.isEnabled })
        let rules = (try? ctx.fetch(descriptor)) ?? []
        cachedRules = rules
        // Rebuild regex cache — reuse compiled regex for same pattern.
        var newCache: [UUID: NSRegularExpression] = [:]
        for rule in rules where rule.isRegex && !rule.pattern.isEmpty {
            if let existing = cachedRegex[rule.id],
               existing.pattern == rule.pattern,
               existing.options == (rule.isCaseSensitive ? [] : .caseInsensitive) {
                newCache[rule.id] = existing
            } else {
                let options: NSRegularExpression.Options = rule.isCaseSensitive ? [] : .caseInsensitive
                if let regex = try? NSRegularExpression(pattern: rule.pattern, options: options) {
                    newCache[rule.id] = regex
                }
            }
        }
        cachedRegex = newCache
    }

    func invalidateCache() { refreshCache(force: true) }

    /// Called from PTYSession.yieldOutput for each chunk. Synchronous, must be fast.
    func processOutput(_ text: String, paneID: UUID? = nil, ptySession: PTYSession?) {
        guard modelContext != nil else { return }
        // Refresh at most once per second, not per chunk.
        if Date().timeIntervalSince(lastCacheRefresh) >= cacheTTL {
            refreshCache()
        }
        guard !cachedRules.isEmpty else { return }
        // Fast-path: if no rule pattern appears as substring, skip regex.
        // Throttle per rule+pane
        for rule in cachedRules {
            let paneKey = paneID?.uuidString ?? "global"
            let key = "\(rule.id.uuidString)-\(paneKey)"
            if let last = lastFire[key], Date().timeIntervalSince(last) < throttleInterval { continue }
            let matched = matchesCached(rule: rule, text: text)
            if matched {
                lastFire[key] = Date()
                dispatch(rule: rule, text: text, paneID: paneID, ptySession: ptySession)
            }
        }
    }

    private func matchesCached(rule: TriggerRule, text: String) -> Bool {
        let pattern = rule.pattern
        guard !pattern.isEmpty else { return false }
        if rule.isRegex {
            guard let regex = cachedRegex[rule.id] else { return false }
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        } else {
            if rule.isCaseSensitive {
                return text.contains(pattern)
            } else {
                return text.range(of: pattern, options: .caseInsensitive) != nil
            }
        }
    }

    private func matches(rule: TriggerRule, text: String) -> Bool {
        let pattern = rule.pattern
        guard !pattern.isEmpty else { return false }
        if rule.isRegex {
            let options: NSRegularExpression.Options = rule.isCaseSensitive ? [] : .caseInsensitive
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        } else {
            if rule.isCaseSensitive {
                return text.contains(pattern)
            } else {
                return text.lowercased().contains(pattern.lowercased())
            }
        }
    }

    private func dispatch(rule: TriggerRule, text: String, paneID: UUID? = nil, ptySession: PTYSession?) {
        switch rule.actionType {
        case .highlight:
            // For now, just log and post notification for UI to highlight (future: inline mark)
            logger.info("Trigger hit [\(rule.name, privacy: .public)] highlight: \(text.prefix(80), privacy: .public)")
            NotificationCenter.default.post(name: .triggerDidHighlight, object: nil, userInfo: ["ruleID": rule.id, "text": text])
        case .notify:
            let title = rule.actionPayload ?? rule.name
            let body = String(text.prefix(200))
            logger.info("Trigger hit [\(rule.name, privacy: .public)] notify")
            Task { await self.sendNotification(title: title, body: body) }
        case .sendText:
            guard let payload = rule.actionPayload, !payload.isEmpty else { return }
            logger.info("Trigger hit [\(rule.name, privacy: .public)] sendText: \(payload, privacy: .public)")
            // Send payload plus newline to the PTY
            let bytes = Array((payload + "\n").utf8)[...]
            Task { try? await ptySession?.sendInput(bytes) }
        }
    }

    private func sendNotification(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}

extension Notification.Name {
    static let triggerDidHighlight = Notification.Name("TriggerDidHighlight")
}
