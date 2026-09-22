//  InlineSuggestionCache.swift
//  Bonk
//
//  In-memory + persistent cache for Inline suggestions.
//  Wraps InlineSuggestionRecord (SwiftData) and 12-segment key generation.
//

import AppKit
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
    /// Coalescing window for disk writes. Memory state applies instantly;
    /// SwiftData saves wait for quiet, resign-active, or terminate.
    private static let saveDebounceNs: UInt64 = 2_000_000_000

    private var saveTask: Task<Void, Never>?
    private nonisolated(unsafe) var lifecycleObservers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(
                forName: NSApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.flush() }
            },
            center.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.flush() }
            },
        ]
    }

    deinit {
        let observers = lifecycleObservers
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Memory state applies instantly; this only schedules the disk write.
    /// Never call modelContext.save() directly from the keystroke path.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounceNs)
            guard !Task.isCancelled else { return }
            try? self?.modelContext?.save()
        }
    }

    /// Immediate disk write: resign-active, terminate, and tests.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        try? modelContext?.save()
    }

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
        scheduleSave()
    }

    func markAccepted(for key: String) {
        guard let rec = persistent[key] else { return }
        rec.acceptCount += 1
        rec.lastUsedAt = Date()
        scheduleSave()
    }

    func markRejected(suffix: String, for key: String) {
        if let rec = persistent[key] {
            rec.rejectCount += 1
            scheduleSave()
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
