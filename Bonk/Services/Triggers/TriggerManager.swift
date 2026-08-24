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

    private init() {}

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Called from PTYSession.yieldOutput for each chunk. Synchronous, must be fast.
    func processOutput(_ text: String, paneID: UUID? = nil, ptySession: PTYSession?) {
        guard let ctx = modelContext else { return }
        // Fetch enabled rules (small set, fetch each time is okay; could cache)
        let descriptor = FetchDescriptor<TriggerRule>(predicate: #Predicate { $0.isEnabled })
        guard let rules = try? ctx.fetch(descriptor), !rules.isEmpty else { return }
        // Throttle per rule+pane
        for rule in rules {
            let paneKey = paneID?.uuidString ?? "global"
            let key = "\(rule.id.uuidString)-\(paneKey)"
            if let last = lastFire[key], Date().timeIntervalSince(last) < throttleInterval { continue }
            let matched = matches(rule: rule, text: text)
            if matched {
                lastFire[key] = Date()
                dispatch(rule: rule, text: text, paneID: paneID, ptySession: ptySession)
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
