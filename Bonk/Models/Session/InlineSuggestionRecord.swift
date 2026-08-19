//
//  InlineSuggestionRecord.swift
//  Bonk
//
//  Persistent cache for inline completion suggestions, keyed by a versioned
//  host/model/endpoint/shell/cwd/context/prefix key.
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
