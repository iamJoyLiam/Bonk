//  CompositeCommandIndex.swift
//  Bonk
//
//  Unified command index combining builtin curated catalog and PATH executables.
//

import Foundation

final class CompositeCommandIndex: CommandIndex, @unchecked Sendable {
    static let shared = CompositeCommandIndex()

    private let builtin: BuiltinCommandIndex
    private let pathIndex: PATHCommandIndex

    init(
        builtin: BuiltinCommandIndex = .shared,
        pathIndex: PATHCommandIndex = .shared
    ) {
        self.builtin = builtin
        self.pathIndex = pathIndex
    }

    func matches(prefix: String, limit: Int = 5) -> [InlineCandidate] {
        let builtinMatches = builtin.matches(prefix: prefix, limit: limit)
        if builtinMatches.count >= limit {
            return builtinMatches
        }

        let remaining = limit - builtinMatches.count
        let pathMatches = pathIndex.matches(prefix: prefix, limit: remaining)
        return builtinMatches + pathMatches
    }
}
