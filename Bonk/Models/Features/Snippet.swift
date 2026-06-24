//
//  Snippet.swift
//  Bonk
//

import Foundation
import SwiftData

/// A reusable command snippet with optional variable placeholders.
@Model
final class Snippet {
    var id: UUID
    var name: String
    var command: String
    var category: String
    var snippetDescription: String
    var sortOrder: Int
    var createdAt: Date

    init(
        name: String,
        command: String,
        category: String = "General",
        description: String = "",
        sortOrder: Int = 0
    ) {
        id = UUID()
        self.name = name
        self.command = command
        self.category = category
        snippetDescription = description
        self.sortOrder = sortOrder
        createdAt = Date()
    }

    /// Resolve variables in the command string.
    /// Supported variables: {host}, {user}, {port}, {date}, {time}
    func resolve(host: String? = nil, user: String? = nil, port: Int? = nil) -> String {
        var result = command
        if let host { result = result.replacingOccurrences(of: "{host}", with: host) }
        if let user { result = result.replacingOccurrences(of: "{user}", with: user) }
        if let port { result = result.replacingOccurrences(of: "{port}", with: "\(port)") }
        let now = Date()
        result = result.replacingOccurrences(of: "{date}", with: Snippet.dateFormatter.string(from: now))
        result = result.replacingOccurrences(of: "{time}", with: Snippet.timeFormatter.string(from: now))
        return result
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
