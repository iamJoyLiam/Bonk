//  CommandIndex.swift
//  Bonk
//
//  Protocol for command indexing services.
//

import Foundation

/// Defines an index that provides prefix matching for commands.
protocol CommandIndex: Sendable {
    func matches(prefix: String, limit: Int) -> [InlineCandidate]
}
