//  InlineSuggestionCache.swift
//  Bonk
//
//  In-memory + persistent cache for Inline suggestions.
//  Wraps InlineSuggestionRecord (SwiftData) and 12-segment key generation.
//

import Foundation
import SwiftData

@MainActor
final class InlineSuggestionCache {
    private var memory: [String: String] = [:]
    private var persistent: [String: InlineSuggestionRecord] = [:]
    private var modelContext: ModelContext?
    private static let memoryLimit = 200
    private static let persistentLimit = 500
    private static let ttl: TimeInterval = 7 * 24 * 60 * 60
    private static let separator = "\u{001E}"

    private var rejected: Set<String> = []

    func attachModelContext(_ context: ModelContext) {
        modelContext = context
        loadPersistent()
    }

    private func loadPersistent() {
        guard let modelContext else { return }
        let desc = FetchDescriptor<InlineSuggestionRecord>()
        guard let records = try? modelContext.fetch(desc) else { return }
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        let active = records.filter { $0.lastUsedAt >= cutoff }
        for r in records where r.lastUsedAt < cutoff { modelContext.delete(r) }
        persistent = Dictionary(uniqueKeysWithValues: active.map { ($0.key, $0) })
        trimPersistent()
        try? modelContext.save()
    }

    func cachedSuffix(for key: String) -> String? {
        if let m = memory[key] { return m }
        return persistent[key]?.suffix
    }

    func store(suffix: String, for key: String) {
        memory[key] = suffix
        if memory.count > Self.memoryLimit { memory.removeAll() }
        if let existing = persistent[key] {
            existing.suffix = suffix
            existing.lastUsedAt = Date()
        } else if let ctx = modelContext {
            let rec = InlineSuggestionRecord(key: key, suffix: suffix)
            ctx.insert(rec)
            persistent[key] = rec
        }
        trimPersistent()
        try? modelContext?.save()
    }

    func markAccepted(for key: String) {
        guard let rec = persistent[key] else { return }
        rec.acceptCount += 1
        rec.lastUsedAt = Date()
        try? modelContext?.save()
    }

    func markRejected(suffix: String, for key: String) {
        if let rec = persistent[key] {
            rec.rejectCount += 1
            try? modelContext?.save()
        }
        rejected.insert(key + "|" + suffix)
    }

    func isRejected(key: String, suffix: String) -> Bool {
        rejected.contains(key + "|" + suffix)
    }

    private func trimPersistent() {
        guard persistent.count > Self.persistentLimit else { return }
        let sorted = persistent.values.sorted { $0.lastUsedAt < $1.lastUsedAt }
        let overflow = sorted.prefix(persistent.count - Self.persistentLimit)
        for r in overflow {
            persistent.removeValue(forKey: r.key)
            modelContext?.delete(r)
        }
    }

    // MARK: - Key generation (12 segments, must stay identical to legacy)

    static func cacheKey(provider: AIProviderConfig, snapshot: CommandContextSnapshot, typed: String) -> String {
        [
            "v2",
            provider.id.uuidString,
            AIProviderNetworking.baseEndpoint(provider.endpoint),
            provider.model,
            provider.protocolType.rawValue,
            snapshot.hostKey ?? "",
            snapshot.currentDirectory ?? "",
            snapshot.shell ?? "",
            typed,
            snapshot.lastExitCode.map(String.init) ?? "",
            snapshot.recentCommands.suffix(5).joined(separator: "\u{1F}"),
            String(snapshot.recentOutput.suffix(160)),
        ]
        .map { $0.replacingOccurrences(of: separator, with: " ") }
        .joined(separator: separator)
    }

    func approvedExamples(for hostKey: String) -> [String] {
        persistent.values
            .filter {
                guard $0.acceptCount > 0 else { return false }
                let fields = $0.key.components(separatedBy: Self.separator)
                return fields.count > 8 && fields[5] == hostKey
            }
            .sorted { $0.acceptCount > $1.acceptCount }
            .prefix(5)
            .map { rec in
                let fields = rec.key.components(separatedBy: Self.separator)
                let typed = fields.count > 8 ? fields[8] : ""
                return "\(typed) → \(rec.suffix)"
            }
    }
}
