import Foundation
import os.log
import SQLite3
import SwiftData

/// The single place a `ModelContainer` may be built.
///
/// ## Why this exists
///
/// On 2026-09-23 and again on 2026-09-29 the production store was found with
/// every entity table DROPped. The 22:53 snapshot held only CoreData's
/// bookkeeping tables plus one stray `ZAPIREQUESTMODEL` — a table that exists
/// in no commit and on no branch. A scratch `ModelContainer` had been built
/// from a schema listing that model and none of the production entities, and
/// because it specified neither `isStoredInMemoryOnly` nor an explicit `url`,
/// it silently defaulted to the production file. SwiftData's migration then
/// dropped every table outside the schema it was handed.
///
/// The whole failure fits in one defaulted argument. So the invariant here is
/// not "remember to pass a url" — it is that **only this file may construct a
/// container**, and `makeTest` cannot name the production path at all.
///
/// ## Rules
///
/// - Production goes through `makeProduction()` and nowhere else.
/// - Tests go through `makeTest(at:)`, which requires an explicit URL the
///   caller must have created under a temporary directory.
/// - No other initializer is exposed. `ModelContainer(for:configurations:)`
///   called directly in app or test code is a CI failure
///   (`StoreConfigurationSafetyTests`).
enum BonkStore {
    private static let logger = Logger(subsystem: "com.bonk.app", category: "Store")

    /// Every persisted entity, in one place.
    ///
    /// An entity missing from this list loses its table on the next migration,
    /// silently, with no error at the call site. `StoreConfigurationSafetyTests`
    /// cross-checks this list against every `@Model` in the app.
    enum Schema {
        static var current: SwiftData.Schema {
            SwiftData.Schema([
                HostItem.self, UserPreferences.self, Credential.self, HostGroup.self,
                AIConversationRecord.self, AIMessageRecord.self, AIProviderRecord.self,
                Snippet.self, PortForward.self, JumpHost.self, InlineSuggestionRecord.self,
                SSHBackendProfile.self, TriggerRule.self,
                LogProfile.self, LogPatternRow.self,
            ])
        }

        /// Entity names in declaration order — the contract a version bump is
        /// measured against, and what the deletion gate compares.
        static var entityNames: [String] {
            [
                "HostItem", "UserPreferences", "Credential", "HostGroup",
                "AIConversationRecord", "AIMessageRecord", "AIProviderRecord",
                "Snippet", "PortForward", "JumpHost", "InlineSuggestionRecord",
                "SSHBackendProfile", "TriggerRule", "LogProfile", "LogPatternRow",
            ]
        }

        /// Entities deliberately removed from the schema, mapped to the reason.
        ///
        /// Removing an entity drops its table and every row of user data, so it
        /// is never a side effect — it is an entry here. Empty today because
        /// nothing has ever been intentionally removed; the 2026-09-29 wipe was
        /// not one of these, it was an unintended DROP of all fifteen.
        ///
        /// To approve a deletion: add `"EntityName": "reason and issue link"`,
        /// remove it from `entityNames` and the schema literal above, and remove
        /// it from `StoreSchemaContract.baselineEntityNames`. All three edits
        /// are required, which is the point.
        static let approvedEntityDeletions: [String: String] = [:]
    }

    /// AGENTS.md: never change `storeName`. It must stay the implicit default
    /// so the file keeps its path and iCloud sync keeps working.
    static let storeName = "default.store"

    /// The one and only production store.
    static func makeProduction() throws -> ModelContainer {
        let schema = Schema.current
        // No explicit store name, and DEBUG resolves to memory. Both are
        // deliberate; see the type comment.
        #if DEBUG
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        #else
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        #endif
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fatal rather than silently falling back to a fresh store: a new
            // empty file at the production path is indistinguishable from a
            // wipe, which is the failure this whole layer exists to prevent.
            logger.fault("Production ModelContainer failed: \(error.localizedDescription, privacy: .public)")
            fatalError("Database initialization failed: \(error)")
        }
    }

    /// A container for tests and diagnostics.
    ///
    /// `url` is required and must point somewhere the caller controls. There is
    /// deliberately no default and no "use a temp file for me" overload: the
    /// one bug in this layer's history came from a URL nobody chose.
    static func makeTest(at url: URL) throws -> ModelContainer {
        let schema = Schema.current
        let config = ModelConfiguration("test", schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Host rows in a store file, read straight from SQLite.
    ///
    /// A container that ignored its `url:` still returns a working
    /// `ModelContainer`, and every assertion against *that container* passes —
    /// while the rows land in the user's real host list. Verified during
    /// development: mutating `makeTest` to drop its URL argument compiled,
    /// returned a container, satisfied every in-container assertion, and wrote
    /// four fixture rows into production.
    ///
    /// So the assertion has to look at files rather than at the container. This
    /// is the only sanctioned way to do that, and it only ever reads.
    static func hostRows(in url: URL) -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db
        else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZHOSTITEM", -1, &stmt, nil) == SQLITE_OK,
              let stmt, sqlite3_step(stmt) == SQLITE_ROW
        else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// A container that never touches the filesystem.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema.current
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// A fresh empty directory under the system temporary directory. Tests
    /// should pass the result of this to `makeTest(at:)` so a stray write can
    /// never land in Application Support.
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonk-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
