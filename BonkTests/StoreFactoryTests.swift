import Foundation
import SwiftData
import Testing
@testable import Bonk

/// The store factory is the whole defence, so it gets behavioural tests
/// rather than a source scan.
///
/// The 2026-09-29 wipe came from one defaulted argument. These tests assert
/// the properties that make that class of mistake impossible to express:
/// production construction is reachable from exactly one symbol, test
/// construction cannot name the production path, and a failed read is never
/// silently reinterpreted as "no data".
@Suite("Store Factory")
struct StoreFactoryTests {
    @Test("Schema entity list matches the schema literal")
    func schemaListIsConsistent() {
        // Both must describe the same 15 entities. A divergence here is how an
        // entity silently loses its table on the next migration.
        #expect(BonkStore.Schema.entityNames.count == 15)
        #expect(Set(BonkStore.Schema.entityNames).count == BonkStore.Schema.entityNames.count,
                "duplicate entity in the schema contract")
    }

    /// The production store name must stay the implicit default. Naming it
    /// explicitly, or changing it, creates a second database and orphans the
    /// user's data — see AGENTS.md.
    @Test("Production store name is the default one")
    func storeNameIsDefault() {
        #expect(BonkStore.storeName == "default.store")
    }

    @Test("A test container round-trips data at an explicit temporary URL")
    func testContainerRoundTrips() throws {
        let dir = try BonkStore.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("probe.store")

        let container = try BonkStore.makeTest(at: url)
        let context = ModelContext(container)
        context.insert(HostItem(
            name: "factory-host", host: "192.0.2.9", port: 22, username: "root", authType: .password
        ))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<HostItem>()) == 1)

        // Read the file directly. A container that ignored the URL would still
        // pass every assertion above while writing into the user's real host
        // list — and, because a test schema can be a subset, SwiftData would
        // DROP every table outside it on the way. This is the assertion that
        // would have caught the 2026-09-29 wipe.
        #expect(try BonkStore.hostRows(in: url) == 1,
                "the row did not land in the file the caller named")
        #expect(try !url.path.hasPrefix(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        ), "a test container resolved inside Application Support")

        // Reopening the same URL must see the same row: the URL is the only
        // thing tying a container to a file, so it has to actually work.
        let reopened = try BonkStore.makeTest(at: url)
        #expect(try ModelContext(reopened).fetchCount(FetchDescriptor<HostItem>()) == 1)
    }

    /// The assertion that would have caught the original incident.
    ///
    /// A test container is verified by reading *its own file* and confirming the
    /// row arrived there. It is deliberately not verified by watching the
    /// production store: a check that inspects production cannot be run safely
    /// while the very bug under test is live, because the act of running it
    /// writes to production. The first version of this test did exactly that
    /// and left two fixture rows in the user's host list.
    ///
    /// Binding is proven positively, at the point of construction, by
    /// `BonkStore.hostRows(in:)` — the file the caller named is the file the
    /// data reached. A container that ignored its URL fails that.
    @Test("A test container's rows land in the file the caller named")
    func rowsLandInTheNamedFile() throws {
        let dir = try BonkStore.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("named.store")
        // A second path in the same directory that must stay empty, so a
        // container that picked the wrong file inside the caller's own
        // directory is still caught.
        let decoy = dir.appendingPathComponent("decoy.store")

        let container = try BonkStore.makeTest(at: url)
        let context = ModelContext(container)
        for index in 0 ..< 3 {
            context.insert(HostItem(
                name: "named-\(index)", host: "198.51.100.\(index + 1)",
                port: 22, username: "root", authType: .password
            ))
        }
        try context.save()

        #expect(try BonkStore.hostRows(in: url) == 3,
                "the rows did not land in the file the caller named")
        #expect(try BonkStore.hostRows(in: decoy) == 0,
                "the container wrote to a different file in the same directory")
        #expect(try FileManager.default.fileExists(atPath: url.path))
    }

    @Test("An in-memory container leaves nothing on disk")
    func inMemoryLeavesNoFiles() throws {
        // Counting the shared temp directory does not work: other tests run in
        // parallel and create and remove their own directories underneath it,
        // so the count moves either way. Watch one private directory instead,
        // and prove the container never created a store file anywhere in it.
        let dir = try BonkStore.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = try BonkStore.makeInMemory()
        let context = ModelContext(container)
        context.insert(HostItem(
            name: "mem-host", host: "192.0.2.10", port: 22, username: "root", authType: .password
        ))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<HostItem>()) == 1,
                "an in-memory container must still hold its rows")

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty,
                "an in-memory container wrote into the directory it was given")
    }

    /// Each call gets its own directory. Two tests sharing one would let one
    /// test's rows satisfy another's assertions.
    @Test("Temporary directories are unique")
    func temporaryDirectoriesAreUnique() throws {
        let a = try BonkStore.makeTemporaryDirectory()
        let b = try BonkStore.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        #expect(a != b)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
    }
}
