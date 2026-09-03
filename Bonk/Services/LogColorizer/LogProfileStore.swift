import Foundation
import SwiftData
import os.log

// Snapshot cache for background thread (no MainActor hop)
enum LogSnapshot {
    nonisolated(unsafe) private static var _map: [UUID: [LogFieldPattern]] = [:]
    nonisolated(unsafe) private static var _active: [LogFieldPattern] = LogPatterns.allPatterns
    private static let lock = NSLock()

    static func update(map: [UUID: [LogFieldPattern]], active: [LogFieldPattern]) {
        lock.lock(); _map = map; _active = active; lock.unlock()
    }

    static func patterns(for host: HostItem?) -> [LogFieldPattern] {
        lock.lock(); defer { lock.unlock() }
        if let hid = host?.logProfile?.id, let arr = _map[hid], !arr.isEmpty { return arr }
        if !_active.isEmpty { return _active }
        return LogPatterns.allPatterns
    }

    static var active: [LogFieldPattern] {
        lock.lock(); defer { lock.unlock() }
        return _active.isEmpty ? LogPatterns.allPatterns : _active
    }
}

@MainActor
@Observable
final class LogProfileStore {
    static let shared = LogProfileStore()

    private var container: ModelContainer?
    private let logger = Logger(subsystem: "Bonk", category: "LogProfileStore")
    private let activeKey = "logActiveProfileID"

    var profiles: [LogProfile] = []
    var activeProfileID: UUID? {
        didSet {
            if let id = activeProfileID { UserDefaults.standard.set(id.uuidString, forKey: activeKey) }
            rebuildSnapshot()
        }
    }

    var activeProfile: LogProfile? {
        if let id = activeProfileID { return profiles.first { $0.id == id } }
        return profiles.first { $0.isDefault } ?? profiles.first
    }

    func configure(container: ModelContainer) {
        self.container = container
        Task { await load() }
    }

    func load() async {
        guard let container else { return }
        let ctx = ModelContext(container)
        let desc = FetchDescriptor<LogProfile>(sortBy: [SortDescriptor(\.createdAt)])
        do {
            profiles = try ctx.fetch(desc)
            if profiles.isEmpty {
                await seedDefaults(ctx: ctx)
                profiles = try ctx.fetch(desc)
            }
            // Migrate old Default colors/patterns (ip 1;34 → cyan, logfmt 1;35 → orange, jsonLevel specific → generic)
            if migrateIfNeeded(profiles: profiles, ctx: ctx) {
                try? ctx.save()
                profiles = try ctx.fetch(desc)
            }
            if activeProfileID == nil {
                if let saved = UserDefaults.standard.string(forKey: activeKey), let uuid = UUID(uuidString: saved),
                   profiles.contains(where: { $0.id == uuid }) {
                    activeProfileID = uuid
                } else {
                    activeProfileID = profiles.first { $0.isDefault }?.id ?? profiles.first?.id
                }
            }
            rebuildSnapshot()
        } catch {
            logger.error("load failed: \(error.localizedDescription)")
        }
    }

    private func rebuildSnapshot() {
        var map: [UUID: [LogFieldPattern]] = [:]
        for profile in profiles {
            let compiled = profile.patterns.filter { $0.enabled }.compactMap { row -> LogFieldPattern? in
                guard let regex = try? NSRegularExpression(pattern: row.pattern, options: [.caseInsensitive]) else { return nil }
                return LogFieldPattern(row.name, regex, row.ansiCode, row.priority)
            }
            map[profile.id] = compiled.isEmpty ? LogPatterns.allPatterns : compiled
        }
        let active = activeProfile
        let activePatterns = active.flatMap { map[$0.id] } ?? LogPatterns.allPatterns
        LogSnapshot.update(map: map, active: activePatterns)
    }

    private func migrateIfNeeded(profiles: [LogProfile], ctx: ModelContext) -> Bool {
        var changed = false
        for profile in profiles where profile.isDefault {
            for row in profile.patterns {
                if row.name == "ip", row.ansiCode == "1;34" {
                    row.ansiCode = "38;2;0;199;190"; changed = true
                }
                if row.name == "logfmtLevel", row.ansiCode == "1;35" {
                    row.ansiCode = "38;2;255;149;0"; changed = true
                }
                if row.name == "jsonLevel", row.pattern == "\"(?:level|severity)\"\\s*:\\s*\"(?:error|warn|info|debug|trace|fatal|emerg|alert|crit)\"" {
                    row.pattern = "\"(?:level|severity)\"\\s*:\\s*\"[^\"]+\""; changed = true
                }
                if row.name == "logfmtLevel", row.pattern == "\\blevel=(?:error|warn|info|debug)\\b" {
                    row.pattern = "\\blevel=(?:error|warn|info|debug|trace|fatal|emerg|alert|crit)\\b"; changed = true
                }
            }
        }
        return changed
    }

    private func seedDefaults(ctx: ModelContext) async {
        let def = LogProfile(name: "Default", isDefault: true)
        for (notification, pat, ansi, pri) in LogPatterns.seedDefinitions {
            let row = LogPatternRow(name: notification, pattern: pat, ansiCode: ansi, priority: pri, profile: def)
            def.patterns.append(row)
            ctx.insert(row)
        }
        ctx.insert(def)

        let nginx = LogProfile(name: "Nginx")
        let npValue = LogPatternRow(name: "nginx", pattern: "\\d{4}/\\d{2}/\\d{2} \\d{2}:\\d{2}:\\d{2} \\[(?:emerg|alert|crit|error|warn|notice|info|debug)\\]", ansiCode: "1;31", priority: 15, profile: nginx)
        nginx.patterns = [npValue]; ctx.insert(npValue); ctx.insert(nginx)

        let json = LogProfile(name: "JSON")
        let jpValue = LogPatternRow(name: "jsonLevel", pattern: "\"(?:level|severity)\"\\s*:\\s*\"[^\"]+\"", ansiCode: "1;35", priority: 40, profile: json)
        json.patterns = [jpValue]; ctx.insert(jpValue); ctx.insert(json)

        try? ctx.save()
        logger.info("seeded 3 default log profiles")
    }

    func create(name: String) -> LogProfile? {
        guard let container else { return nil }
        let ctx = ModelContext(container)
        let profile = LogProfile(name: name)
        ctx.insert(profile)
        try? ctx.save()
        Task { await load() }
        return profile
    }

    func delete(_ profile: LogProfile) {
        guard let container else { return }
        let ctx = ModelContext(container)
        let pid = profile.id
        if let target = try? ctx.fetch(FetchDescriptor<LogProfile>(predicate: #Predicate { $0.id == pid })).first {
            ctx.delete(target)
            try? ctx.save()
        } else {
            ctx.delete(profile)
            try? ctx.save()
        }
        if activeProfileID == profile.id { activeProfileID = profiles.first { $0.id != profile.id }?.id }
        Task { await load() }
    }

    func addRow(to profile: LogProfile, name: String, pattern: String, ansiCode: String, priority: Int) -> Bool {
        guard (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil else { return false }
        guard let container else { return false }
        let ctx = ModelContext(container)
        let pid = profile.id
        guard let profile = try? ctx.fetch(FetchDescriptor<LogProfile>(predicate: #Predicate { $0.id == pid })).first else { return false }
        let row = LogPatternRow(name: name, pattern: pattern, ansiCode: ansiCode, priority: priority, profile: profile)
        profile.patterns.append(row)
        ctx.insert(row)
        try? ctx.save()
        Task { await load() }
        return true
    }

    // Resolver for UI thread (MainActor)
    func patterns(for host: HostItem?) -> [LogFieldPattern] {
        LogSnapshot.patterns(for: host)
    }

    var snapshot: [LogFieldPattern] { LogSnapshot.active }

    func refreshSnapshot() { rebuildSnapshot() }
}

extension LogFieldPattern {
    init(_ name: String, _ regex: NSRegularExpression, _ ansiCode: String, _ priority: Int) {
        self.name = name
        self.regex = regex
        self.ansiCode = ansiCode
        self.priority = priority
    }
}
