import Foundation
import SwiftData
import os.log

@Observable
final class LogProfileStore: @unchecked Sendable {
    static let shared = LogProfileStore()

    private var container: ModelContainer?
    private let logger = Logger(subsystem: "Bonk", category: "LogProfileStore")
    private let lock = NSLock()
    private var _cachedPatterns: [LogFieldPattern] = LogPatterns.allPatterns

    var profiles: [LogProfile] = []
    var activeProfileID: UUID?

    var activeProfile: LogProfile? {
        lock.lock(); defer { lock.unlock() }
        if let id = activeProfileID { return profiles.first { $0.id == id } }
        return profiles.first { $0.isDefault } ?? profiles.first
    }

    func configure(container: ModelContainer) {
        self.container = container
        Task { await load() }
    }

    @MainActor
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
            if activeProfileID == nil {
                activeProfileID = profiles.first { $0.isDefault }?.id ?? profiles.first?.id
            }
            updateCache()
        } catch {
            logger.error("load failed: \(error.localizedDescription)")
        }
    }

    private func updateCache() {
        lock.lock(); defer { lock.unlock() }
        if let active = profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first(where: { $0.isDefault }) ?? profiles.first {
            _cachedPatterns = active.patterns.filter { $0.enabled }.compactMap { row in
                guard let re = try? NSRegularExpression(pattern: row.pattern, options: [.caseInsensitive]) else { return nil }
                return LogFieldPattern(row.name, re, row.ansiCode, row.priority)
            }
            if _cachedPatterns.isEmpty { _cachedPatterns = LogPatterns.allPatterns }
        }
    }

    private func seedDefaults(ctx: ModelContext) async {
        // Default — mirrors LogPatterns.allPatterns
        let def = LogProfile(name: "Default", isDefault: true)
        let defaults: [(String,String,String,Int)] = [
            ("emerg","(?<![A-Za-z0-9_\\-])(?:EMERG(?:ENCY)?|PANIC)(?![A-Za-z0-9_\\-])","1;41;97",10),
            ("alert","(?<![A-Za-z0-9_\\-])ALERT(?![A-Za-z0-9_\\-])","1;41;97",11),
            ("crit","(?<![A-Za-z0-9_\\-])(?:CRIT(?:ICAL)?)(?![A-Za-z0-9_\\-])","1;91",12),
            ("fatal","(?<![A-Za-z0-9_\\-])FATAL(?![A-Za-z0-9_\\-])","1;91",13),
            ("error","(?<![A-Za-z0-9_\\-])(?:ERR(?:OR)?)(?![A-Za-z0-9_\\-])","1;31",14),
            ("warn","(?<![A-Za-z0-9_\\-])(?:WARN(?:ING)?)(?![A-Za-z0-9_\\-])","1;33",20),
            ("info","(?<![A-Za-z0-9_\\-])(?:INFO(?:RMATIONAL)?)(?![A-Za-z0-9_\\-])","1;34",30),
            ("debug","(?<![A-Za-z0-9_\\-])(?:DEBUG|TRACE)(?![A-Za-z0-9_\\-])","2",35),
            ("ip","\\b(?:(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\b","1;34",50),
            ("timestamp","\\d{4}[-/]\\d{2}[-/]\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?","2;32",60),
            ("jsonLevel","\"(?:level|severity)\"\\s*:\\s*\"(?:error|warn|info|debug|trace|fatal|emerg|alert|crit)\"","1;35",40),
            ("logfmtLevel","\\blevel=(?:error|warn|info|debug|trace|fatal|emerg|alert|crit)\\b","1;35",41),
        ]
        for (n,p,c,pr) in defaults {
            let row = LogPatternRow(name: n, pattern: p, ansiCode: c, priority: pr, profile: def)
            def.patterns.append(row)
            ctx.insert(row)
        }
        ctx.insert(def)

        // Nginx
        let nginx = LogProfile(name: "Nginx")
        let np = LogPatternRow(name: "nginx", pattern: "\\d{4}/\\d{2}/\\d{2} \\d{2}:\\d{2}:\\d{2} \\[(?:emerg|alert|crit|error|warn|notice|info|debug)\\]", ansiCode: "1;31", priority: 15, profile: nginx)
        nginx.patterns = [np]; ctx.insert(np); ctx.insert(nginx)

        // JSON
        let json = LogProfile(name: "JSON")
        let jp = LogPatternRow(name: "jsonLevel", pattern: "\"(?:level|severity)\"\\s*:\\s*\"[^\"]+\"", ansiCode: "1;35", priority: 40, profile: json)
        json.patterns = [jp]; ctx.insert(jp); ctx.insert(json)

        try? ctx.save()
        logger.info("seeded 3 default log profiles")
    }

    @MainActor
    func create(name: String) -> LogProfile? {
        guard let container else { return nil }
        let ctx = ModelContext(container)
        let p = LogProfile(name: name)
        ctx.insert(p)
        try? ctx.save()
        Task { await load() }
        return p
    }

    @MainActor
    func delete(_ profile: LogProfile) {
        guard let container else { return }
        let ctx = ModelContext(container)
        ctx.delete(profile)
        try? ctx.save()
        Task { await load() }
    }

    @MainActor
    func addRow(to profile: LogProfile, name: String, pattern: String, ansiCode: String, priority: Int) -> Bool {
        guard (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil else { return false }
        guard let container else { return false }
        let ctx = ModelContext(container)
        if let p = ctx.model(for: profile.id) as? LogProfile {
            let row = LogPatternRow(name: name, pattern: pattern, ansiCode: ansiCode, priority: priority, profile: p)
            p.patterns.append(row)
            ctx.insert(row)
            try? ctx.save()
            Task { await load() }
            return true
        }
        return false
    }

    // Resolve patterns for a host (per-host override or active) — nonisolated for background worker
    nonisolated func patterns(for host: HostItem?) -> [LogFieldPattern] {
        lock.lock(); defer { lock.unlock() }
        if !_cachedPatterns.isEmpty { return _cachedPatterns }
        return LogPatterns.allPatterns
    }

    // Legacy sync version kept for UI thread
    func patternsSync(for host: HostItem?) -> [LogFieldPattern] {
        if let h = host, let pid = h.logProfile?.id, let p = profiles.first(where: { $0.id == pid }) {
            return p.patterns.filter { $0.enabled }.compactMap { row in
                guard let re = try? NSRegularExpression(pattern: row.pattern, options: [.caseInsensitive]) else { return nil }
                return LogFieldPattern(row.name, re, row.ansiCode, row.priority)
            }
        }
        if let active = activeProfile {
            return active.patterns.filter { $0.enabled }.compactMap { row in
                guard let re = try? NSRegularExpression(pattern: row.pattern, options: [.caseInsensitive]) else { return nil }
                return LogFieldPattern(row.name, re, row.ansiCode, row.priority)
            }
        }
        return LogPatterns.allPatterns
    }
}

// Helper to init LogFieldPattern with precompiled regex (bypass string compile)
extension LogFieldPattern {
    init(_ name: String, _ regex: NSRegularExpression, _ ansiCode: String, _ priority: Int) {
        self.name = name
        self.regex = regex
        self.ansiCode = ansiCode
        self.priority = priority
    }
}
