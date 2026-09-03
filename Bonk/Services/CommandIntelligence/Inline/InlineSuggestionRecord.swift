//
//  InlineSuggestionRecord.swift
//  Bonk
//
//  P0 scaffold for the persistent inline suggestion cache record.
//  Behavior and SwiftData schema are unchanged from the legacy model.
//

import Foundation
import SwiftData

@Model
final class InlineSuggestionRecord {
    var key: String
    var suffix: String
    var lastUsedAt: Date
    var acceptCount: Int = 0
    var rejectCount: Int = 0

    init(key: String, suffix: String, lastUsedAt: Date = Date()) {
        self.key = key
        self.suffix = suffix
        self.lastUsedAt = lastUsedAt
        self.acceptCount = 0
        self.rejectCount = 0
    }
}
