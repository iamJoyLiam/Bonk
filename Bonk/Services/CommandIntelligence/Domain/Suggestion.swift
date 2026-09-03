//  Suggestion.swift
//  Bonk
//
//  Domain model for inline ghost — pure value, no logic.
//

import Foundation

struct Suggestion: Sendable, Equatable {
    let text: String          // raw suffix to insert
    let displayText: String   // ghost display (with leading space handling)
}
