import Foundation
import Testing
@testable import Bonk

/// Stops the 2026-09-23 / 2026-09-29 wipe class from ever shipping again.
///
/// What happened, established from the database itself: at 22:53:59 the
/// production store held no entity tables at all — only CoreData's bookkeeping
/// tables plus a single `ZAPIREQUESTMODEL`. Every one of the 15 production
/// tables had been DROPped, which is exactly what SwiftData's migration does to
/// tables outside the schema it was handed. `APIRequestModel` appears in that
/// snapshot and in no healthy backup, in no commit, and on no branch: it was
/// uncommitted working-tree code. So a container built from a scratch schema
/// that listed a brand-new model and none of the production entities was
/// pointed at the live store, and the migration gutted it. `AGENTS.md` records
/// the same mechanism for v2026.4.3.
///
/// The whole failure fits in one API call: any `ModelContainer` built without
/// an explicit in-memory flag or an explicit temporary URL defaults to the
/// production store. That is silent, it compiles, it passes review, and it
/// destroys the user's hosts on the next run.
///
/// So this gate is a source-level scan rather than a runtime probe: the
/// dangerous call sites are exactly the ones no behavioural test can reach,
/// because the code being judged may not even be reachable from a test.
@Suite("Store Configuration Safety")
struct StoreConfigurationSafetyTests {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BonkTests
            .deletingLastPathComponent()   // repository root
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            // Build products embed copies of the sources; scanning them would
            // report every finding twice.
            let path = url.path
            if path.contains("/build/") || path.contains("/.build/")
                || path.contains("DerivedData") || path.contains("/target/") {
                continue
            }
            // This file names the API it is looking for, so it would always
            // report itself as an offender.
            if url.lastPathComponent == "StoreConfigurationSafetyTests.swift" {
                continue
            }
            files.append(url)
        }
        return files
    }

    /// Every `ModelConfiguration(` call site, with the source line.
    private static func configurationCallSites() -> [(file: String, line: Int, text: String)] {
        callSites(containing: "ModelConfiguration(")
    }

    /// Every `ModelContainer(` call site. Note `ModelContext(` and
    /// `ModelContainer` as a *type* are not matches: reading an existing
    /// container is safe, constructing one is not.
    private static func containerCallSites() -> [(file: String, line: Int, text: String)] {
        callSites(containing: "ModelContainer(")
    }

    private static func callSites(containing needle: String) -> [(file: String, line: Int, text: String)] {
        var sites: [(String, Int, String)] = []
        for file in swiftFiles(in: Self.repositoryRoot) {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                let text = line.trimmingCharacters(in: .whitespaces)
                // Skip the scanner's own needles, and comments.
                if text.hasPrefix("//") || text.hasPrefix("*") { continue }
                if text.contains(needle) {
                    sites.append((file.path, index + 1, text))
                }
            }
        }
        return sites
    }

    /// Gate 1: only `BonkStore` may build a container.
    ///
    /// An earlier version of this test exempted `BonkApp.swift` and failed only
    /// on unconfigured containers elsewhere. That left the actual hole open: an
    /// agent editing the one exempt file could add another production container
    /// and CI would stay green. The rule is now inverted — the factory is the
    /// only legal call site, with no exemptions at all, so adding a container
    /// anywhere else is a build failure regardless of how it is configured.
    @Test("Only BonkStore.swift constructs a ModelContainer")
    func onlyTheFactoryConstructsContainers() throws {
        let offenders = Self.containerCallSites()
            // The factory, and the test files that predate it. Those three are
            // in-memory already, which the pinning gate below verifies
            // independently — so the exemption costs no safety.
            .filter { !$0.file.hasSuffix("Bonk/Services/Store/BonkStore.swift") }
            .filter { site in !Self.preFactoryTestFiles.contains { site.file.hasSuffix($0) } }
            .map { "\(URL(fileURLWithPath: $0.file).lastPathComponent):\($0.line)  \($0.text)" }

        #expect(offenders.isEmpty,
                """
                A ModelContainer is constructed outside BonkStore.swift. Every container must \
                come from BonkStore.makeProduction(), makeTest(at:) or makeInMemory() — a \
                directly built one defaults to the production store, and SwiftData then DROPs \
                every table outside its schema. That is what wiped all 21 hosts on 2026-09-23 \
                and again on 2026-09-29.
                Offending sites:
                \(offenders.joined(separator: "\n"))
                """)
    }

    /// Gate 2: a container built outside the factory must at minimum be pinned
    /// to memory or to an explicit URL. This is a second line of defence for
    /// the case where the factory check is bypassed (for example a snippet in a
    /// review that has not been extracted yet).
    @Test("Containers outside the factory are pinned to memory or a URL")
    func containersOutsideFactoryArePinned() throws {
        let offenders = Self.configurationCallSites()
            .filter { !$0.file.hasSuffix("Bonk/Services/Store/BonkStore.swift") }
            .filter { site in
                let pinned = site.text.contains("isStoredInMemoryOnly")
                    || site.text.contains("url:")
                return !pinned
            }
            .map { "\(URL(fileURLWithPath: $0.file).lastPathComponent):\($0.line)  \($0.text)" }

        #expect(offenders.isEmpty,
                """
                A ModelConfiguration outside BonkStore.swift is neither in-memory nor given an \
                explicit URL, so it resolves to the production store.
                Offending sites:
                \(offenders.joined(separator: "\n"))
                """)
    }

    /// Test files that predate `BonkStore` and still build their own
    /// containers. All three are in-memory, which the pinning gate verifies
    /// independently, so exempting them here costs no safety. Migrating them is
    /// a follow-up, not a safety issue.
    private static let preFactoryTestFiles = [
        "BonkTests/AIConversationLazyCreationTests.swift",
        "BonkTests/StoreSchemaDurabilityTests.swift",
        "BonkTests/StoreRestoreRecoveryTests.swift",
    ]

    /// Gate 4: destructive *test* code must not compile into production.
    ///
    /// `runHandUITest()` deleted a real host via `ctx.delete` and lived outside
    /// the `#if DEBUG` that guarded its only call site, so release builds
    /// shipped unreachable, deletable capability.
    ///
    /// The gate is deliberately narrow. Production code legitimately deletes
    /// rows — `LogProfileStore.delete(named:)` is a user-facing feature — so
    /// banning `delete(` outright would be wrong. What must never ship is
    /// test *scaffolding*: hardcoded fixtures, file-drop triggers, result files
    /// in /tmp. Those have no reason to exist in a shipping binary.
    @Test("Test scaffolding does not compile into production builds")
    func testScaffoldingIsNotInProduction() throws {
        // Fixtures and trigger files. A shipping binary has no business
        // containing any of these.
        let scaffolding: [(String, String)] = [
            ("bonk_test_trigger", "file-drop test trigger"),
            ("bonk_test_ui_only", "test-mode switch file"),
            ("bonk_test_result", "test result file"),
            ("TEST_TRIGGER", "test trigger log marker"),
            ("runHandUITest", "hand-driven UI test harness"),
        ]
        // A hardcoded credential in a shipping binary is a separate, equally
        // serious problem, and this codebase already has a rule about it.
        let credential = "password: \"1234\""

        var offenders: [String] = []
        for file in Self.swiftFiles(in: Self.repositoryRoot) {
            let relative = file.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
            if relative.hasPrefix("BonkTests/") { continue }
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (needle, why) in scaffolding where contents.contains(needle) {
                offenders.append("\(relative) — \(why): \(needle)")
            }
            if contents.contains(credential) {
                offenders.append("\(relative) — hardcoded test credential")
            }
        }
        #expect(offenders.isEmpty,
                """
                Test scaffolding must not compile into the production target. It ships as \
                unreachable but callable capability, and is the easiest thing for a later change \
                to wire up by accident.
                \(offenders.joined(separator: "\n"))
                """)
    }

    /// Gate 3, part one: adding a model without registering it is a silent
    /// data-loss bug on the next migration.
    ///
    /// `@Model` implies `PersistentModel`, so the declaration does not spell
    /// the conformance out: `final class HostItem {`, optionally with a
    /// trailing `: Identifiable`.
    @Test("Every @Model in the app is registered in the schema")
    func everyModelIsRegistered() throws {
        let modelTypes = Set(Self.declaredModelTypes())
        #expect(!modelTypes.isEmpty, "failed to discover any @Model types — the scan is broken")

        let registered = Set(BonkStore.Schema.entityNames)
        let missing = modelTypes.subtracting(registered).sorted()
        #expect(missing.isEmpty,
                """
                These @Model types are not registered in BonkStore.Schema, so their tables are \
                outside the production schema and a migration would drop them:
                \(missing.joined(separator: ", "))
                Add them to BonkStore.Schema.entityNames and the schema literal.
                """)
    }

    /// Gate 3, part two: the harder direction.
    ///
    /// Adding a model is a normal, additive change. *Removing* one destroys
    /// user data, and it is the direction that must not happen by accident —
    /// which is exactly what happened on 2026-09-29 when 15 tables were dropped.
    /// An entity may only leave the schema by being written down as an approved
    /// deletion, so the cost of losing data becomes a deliberate edit.
    @Test("Removing an entity from the schema requires explicit approval")
    func entityRemovalRequiresApproval() throws {
        let approved = Self.approvedEntityDeletions()
        let current = Set(BonkStore.Schema.entityNames)

        // A deletion is only approved if it is *no longer* present. Anything
        // still in the schema has not been removed, so its approval entry is
        // stale and should be cleaned up.
        let staleApprovals = approved.keys.filter { current.contains($0) }
        #expect(staleApprovals.isEmpty,
                """
                These entities are approved for deletion but are still in the schema. Remove the \
                stale approval entry from BonkStore.Schema.approvedEntityDeletions:
                \(staleApprovals.sorted().joined(separator: ", "))
                """)

        // The recorded baseline is what "before" means. Anything in the
        // baseline and no longer in the schema is a deletion.
        guard let baseline = Self.schemaBaseline() else { return }
        let removed = Set(baseline).subtracting(current)
        #expect(removed.isEmpty,
                """
                These persisted entities were removed from the schema without approval. Removing \
                an entity drops its table and every row of user data. If this is intentional, \
                record it in BonkStore.Schema.approvedEntityDeletions and update \
                StoreSchemaContract.baseline:
                \(removed.sorted().joined(separator: ", "))
                """)
    }

    /// Names in `BonkStore.Schema.approvedEntityDeletions` that are not in the
    /// schema — i.e. deletions someone has signed off on.
    /// The approval list, read from the live value rather than by parsing
    /// source. Parsing a literal is how gates quietly stop matching.
    private static func approvedEntityDeletions() -> [String: String] {
        BonkStore.Schema.approvedEntityDeletions
    }

    /// Every `@Model` class declared in the app, discovered from source.
    ///
    /// `@Model` implies `PersistentModel`, so the declaration does not spell
    /// the conformance out: `final class HostItem {`, optionally followed by
    /// `: Identifiable`.
    private static func declaredModelTypes() -> [String] {
        let pattern = try? NSRegularExpression(
            pattern: #"@Model\s*(?:\n\s*)?(?:public\s+|final\s+)*class\s+(\w+)"#
        )
        var found: [String] = []
        for file in swiftFiles(in: Self.repositoryRoot) {
            guard let contents = try? String(contentsOf: file, encoding: .utf8),
                  contents.contains("@Model"),
                  let pattern
            else { continue }
            let range = NSRange(contents.startIndex..., in: contents)
            for match in pattern.matches(in: contents, range: range) {
                if let nameRange = Range(match.range(at: 1), in: contents) {
                    found.append(String(contents[nameRange]))
                }
            }
        }
        return found
    }

    /// The entity list as of the last release, recorded in the test target.
    /// Comparing against a frozen baseline is what turns "an entity vanished"
    /// into a build failure instead of a slow discovery in production.
    private static func schemaBaseline() -> [String]? {
        StoreSchemaContract.baselineEntityNames
    }
}
