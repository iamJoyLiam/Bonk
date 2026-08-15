//
//  InlineSuggestionRecord.swift
//  Bonk
//
//  Persistent cache for inline completion suggestions, keyed by
//  "cwd|provider|typed-prefix" so habits survive restarts without growing
//  the model prompt.
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
