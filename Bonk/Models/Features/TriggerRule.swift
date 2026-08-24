//
//  TriggerRule.swift
//  Bonk
//
//  Regex trigger → highlight / notify / sendText.
//

import Foundation
import SwiftData

enum TriggerActionType: String, Codable, CaseIterable, Sendable {
    case highlight
    case notify
    case sendText

    var displayName: String {
        switch self {
        case .highlight: "Highlight"
        case .notify: "Notify"
        case .sendText: "Send Text"
        }
    }

    func displayName(i18n: I18n) -> String {
        switch self {
        case .highlight: i18n.t(.triggerHighlight)
        case .notify: i18n.t(.triggerNotify)
        case .sendText: i18n.t(.triggerSendText)
        }
    }
}

@Model
final class TriggerRule {
    var id: UUID
    var name: String
    var pattern: String
    var isRegex: Bool
    var isCaseSensitive: Bool
    var actionTypeRaw: String
    var actionPayload: String?
    var isEnabled: Bool
    var createdAt: Date

    var actionType: TriggerActionType {
        get { TriggerActionType(rawValue: actionTypeRaw) ?? .highlight }
        set { actionTypeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        isRegex: Bool = true,
        isCaseSensitive: Bool = false,
        actionType: TriggerActionType = .highlight,
        actionPayload: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.isRegex = isRegex
        self.isCaseSensitive = isCaseSensitive
        self.actionTypeRaw = actionType.rawValue
        self.actionPayload = actionPayload
        self.isEnabled = isEnabled
        self.createdAt = Date()
    }
}
