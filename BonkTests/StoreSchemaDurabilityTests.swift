import Foundation
import SwiftData
import Testing
@testable import Bonk

/// Guards the production store against silent, total data loss.
///
/// Incident (2026-09-29): the live file-backed store was found with every
/// entity table emptied and its primary-key high-water mark reset to zero,
/// then repopulated with nothing but the app's own seed data. The
/// "survivors" were an illusion — `LogProfileStore.seedDefaults` had just
/// re-inserted Default/Nginx/JSON plus 12+1+1 = 14 pattern rows, and
/// `ensurePreferences()` had re-inserted one preferences row. 59 DDL
/// operations, same inode, `integrity_check = ok`, and byte-identical
/// `Z_METADATA` / `Z_MODELCACHE`, so no model-hash mismatch and no corruption
/// explains it. The only signature that fits is a persistence-layer rebuild
/// of the whole file.
///
/// High-water marks are the tell: seeded tables sit at `Z_MAX == count`
/// (1, 3, 14) while real user data showed deletion history
/// (HostItem `Z_MAX` 22 vs 21 rows, SSHBackendProfile 32 vs 22).
///
/// These tests pin the invariant that makes such a rebuild impossible to ship
/// unnoticed: a file-backed store populated through the production schema
/// must still contain every row after the container is closed and reopened.
/// The failure mode is silent — rows vanish on open without any thrown error —
/// so it is asserted on behaviour, not on the presence of guard code.
///
/// Every store here lives in a fresh temporary directory. No test may ever
/// open the live store: a second file-backed container scoped to fewer models
/// DROPs every table outside its schema (AGENTS.md).
@Suite("Store Schema Durability")
struct StoreSchemaDurabilityTests {
    /// Mirrors `BonkApp.sharedModelContainer`. If production changes this list,
    /// this must change with it or the test stops describing production.
    private static let productionSchema = Schema([
        HostItem.self, UserPreferences.self, Credential.self, HostGroup.self,
        AIConversationRecord.self, AIMessageRecord.self, AIProviderRecord.self,
        Snippet.self, PortForward.self, JumpHost.self, InlineSuggestionRecord.self,
        SSHBackendProfile.self, TriggerRule.self,
        LogProfile.self, LogPatternRow.self,
    ])

    /// A container bound to a throwaway directory, never the live store.
    private static func makeContainer(in directory: URL) throws -> ModelContainer {
        let storeURL = directory.appendingPathComponent("durability.store")
        let config = ModelConfiguration("durability", schema: productionSchema, url: storeURL)
        return try ModelContainer(for: productionSchema, configurations: [config])
    }

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonk-durability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func seed(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        let credential = Credential(name: "durability-cred", type: .password)
        let group = HostGroup(name: "durability-group", colorHex: "#FFFFFF", icon: "folder")
        let host = HostItem(
            name: "durability-host",
            host: "192.0.2.1",
            port: 22,
            username: "root",
            authType: .password
        )
        host.credentialRef = credential
        host.groupRef = group
        let profile = LogProfile(name: "durability-profile")
        profile.patterns = [LogPatternRow(name: "durability-pattern", pattern: "x", ansiCode: "1;31", priority: 1)]
        context.insert(credential)
        context.insert(group)
        context.insert(profile)
        context.insert(host)
        try context.save()
    }

    private struct Counts: Equatable {
        var hosts = 0
        var groups = 0
        var credentials = 0
        var logProfiles = 0
        var logPatterns = 0
    }

    private static func counts(_ container: ModelContainer) throws -> Counts {
        let context = ModelContext(container)
        return Counts(
            hosts: try context.fetchCount(FetchDescriptor<HostItem>()),
            groups: try context.fetchCount(FetchDescriptor<HostGroup>()),
            credentials: try context.fetchCount(FetchDescriptor<Credential>()),
            logProfiles: try context.fetchCount(FetchDescriptor<LogProfile>()),
            logPatterns: try context.fetchCount(FetchDescriptor<LogPatternRow>())
        )
    }

    /// Core gate: rows must survive close/reopen. A destructive rebuild shows
    /// up here as zeroed counts, never as a thrown error.
    @Test("Reopening a populated file-backed store loses no rows")
    func reopenPreservesEveryRow() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let container = try Self.makeContainer(in: directory)
            try Self.seed(container)
            #expect(try Self.counts(container).hosts == 1, "seed should insert one host")
        }

        let reopened = try Self.makeContainer(in: directory)
        let after = try Self.counts(reopened)

        #expect(after.hosts == 1, "host rows were destroyed on reopen")
        #expect(after.groups == 1, "host group rows were destroyed on reopen")
        #expect(after.credentials == 1, "credential rows were destroyed on reopen")
        #expect(after.logProfiles == 1, "log profile rows were destroyed on reopen")
        #expect(after.logPatterns == 1, "log pattern rows were destroyed on reopen")
    }

    /// The incident emptied the entity tables but the app repopulated the log
    /// tables from its seed set, so row counts alone can look healthy. Assert
    /// the relationship edges too, so a rebuild cannot quietly nullify
    /// `credentialRef` / `groupRef` while leaving the rows themselves in place.
    @Test("Relationship references survive close/reopen")
    func reopenPreservesRelationshipEdges() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let container = try Self.makeContainer(in: directory)
            try Self.seed(container)
        }

        let reopened = try Self.makeContainer(in: directory)
        let context = ModelContext(reopened)
        let host = try #require(try context.fetch(FetchDescriptor<HostItem>()).first)
        #expect(host.credentialRef != nil, "credentialRef was nullified on reopen")
        #expect(host.groupRef != nil, "groupRef was nullified on reopen")
    }

    /// The incident store was rewritten in place, so second and third launches
    /// had to remain lossless as well. Reopening must be idempotent.
    @Test("Repeated opens stay lossless")
    func repeatedOpensStayLossless() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let container = try Self.makeContainer(in: directory)
            try Self.seed(container)
        }

        for attempt in 1...3 {
            let container = try Self.makeContainer(in: directory)
            let counts = try Self.counts(container)
            #expect(counts.hosts == 1, "hosts lost on open #\(attempt)")
            #expect(counts.credentials == 1, "credentials lost on open #\(attempt)")
            #expect(counts.logProfiles == 1, "log profiles lost on open #\(attempt)")
            #expect(counts.logPatterns == 1, "log patterns lost on open #\(attempt)")
        }
    }

    /// A rebuild that swaps in a fresh file leaves the row counts correct but
    /// silently discards the primary-key high-water marks and the file
    /// identity. Both were part of the incident signature, so pin them: a
    /// store must keep its inode across reopens.
    @Test("Reopen preserves the store file identity")
    func reopenPreservesStoreIdentity() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("durability.store")

        do {
            let container = try Self.makeContainer(in: directory)
            try Self.seed(container)
        }
        let firstInode = try FileManager.default
            .attributesOfItem(atPath: storeURL.path)[.systemFileNumber] as? UInt64

        let reopened = try Self.makeContainer(in: directory)
        _ = try Self.counts(reopened)
        let secondInode = try FileManager.default
            .attributesOfItem(atPath: storeURL.path)[.systemFileNumber] as? UInt64

        #expect(firstInode != nil, "store file vanished after reopen")
        #expect(firstInode == secondInode,
                "reopen replaced the store file — data is silently discarded")
    }
}
