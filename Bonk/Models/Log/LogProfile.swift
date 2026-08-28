import Foundation
import SwiftData

@Model
final class LogProfile {
    var id: UUID
    var name: String
    var isDefault: Bool
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \LogPatternRow.profile)
    var patterns: [LogPatternRow] = []

    init(id: UUID = UUID(), name: String, isDefault: Bool = false, createdAt: Date = Date(), patterns: [LogPatternRow] = []) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.patterns = patterns
    }
}

@Model
final class LogPatternRow {
    var id: UUID
    var name: String
    var pattern: String
    var ansiCode: String
    var priority: Int
    var enabled: Bool
    var createdAt: Date
    var profile: LogProfile?

    init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        ansiCode: String,
        priority: Int = 50,
        enabled: Bool = true,
        createdAt: Date = Date(),
        profile: LogProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.ansiCode = ansiCode
        self.priority = priority
        self.enabled = enabled
        self.createdAt = createdAt
        self.profile = profile
    }
}
