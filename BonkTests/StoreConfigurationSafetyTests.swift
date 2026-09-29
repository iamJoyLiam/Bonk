import Foundation
import Testing

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
        var sites: [(String, Int, String)] = []
        for file in swiftFiles(in: repositoryRoot) {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                if line.contains("ModelConfiguration(") {
                    sites.append((file.path, index + 1, line.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return sites
    }

    /// The single production container in `BonkApp.swift`. Everything else that
    /// builds a container must be pinned to memory or to a throwaway path.
    @Test("Only BonkApp.swift configures a file-backed container")
    func onlyProductionMayUseFileBackedStore() throws {
        let exemptions = [
            "Bonk/BonkApp.swift",             // the one real store
            "BonkTests/StoreSchemaDurabilityTests.swift",  // temp-dir durability probes
            "BonkTests/StoreRestoreRecoveryTests.swift",  // temp-dir snapshot fixtures
        ]
        let offenders = Self.configurationCallSites()
            .filter { site in
                // A configuration that is explicitly in-memory is harmless.
                let pinned = site.text.contains("isStoredInMemoryOnly: true")
                    || site.text.contains("url:")
                guard !pinned else { return false }
                return !exemptions.contains { site.file.hasSuffix($0) }
            }
            .map { "\(URL(fileURLWithPath: $0.file).lastPathComponent):\($0.line)  \($0.text)" }

        #expect(offenders.isEmpty,
                """
                A ModelConfiguration is neither in-memory nor given an explicit URL, so it \
                defaults to the production store. Building a container from it makes SwiftData \
                DROP every table outside its schema — this is what wiped all 21 hosts on \
                2026-09-23 and again on 2026-09-29.
                Offending sites:
                \(offenders.joined(separator: "\n"))
                """)
    }

    /// The mirror image: a container built from a schema that is not the
    /// production schema, aimed at a file-backed store, is the exact shape of
    /// the incident. This also catches a scratch model being added to a test
    /// schema that a future change might make file-backed.
    @Test("Every @Model in the app is covered by the production schema")
    func productionSchemaCoversEveryModel() throws {
        // Every @Model type in the app must appear in BonkApp's schema literal,
        // or it silently loses its table on the next migration.
        // `@Model` implies PersistentModel, so the declaration does not spell
        // the conformance out: `final class HostItem {`, optionally with a
        // trailing `: Identifiable`.
        let pattern = try? NSRegularExpression(
            pattern: #"@Model\s*(?:\n\s*)?(?:public\s+|final\s+)*class\s+(\w+)"#
        )
        let modelTypes = Set(Self.swiftFiles(in: Self.repositoryRoot)
            .compactMap { url -> String? in
                guard let contents = try? String(contentsOf: url, encoding: .utf8),
                      contents.contains("@Model"),
                      let pattern
                else { return nil }
                let range = NSRange(contents.startIndex..., in: contents)
                return pattern.firstMatch(in: contents, range: range)
                    .flatMap { Range($0.range(at: 1), in: contents) }
                    .map { String(contents[$0]) }
            })

        #expect(!modelTypes.isEmpty, "failed to discover any @Model types — the scan is broken")

        guard let appFile = Self.swiftFiles(in: Self.repositoryRoot)
            .first(where: { $0.lastPathComponent == "BonkApp.swift" }),
              let contents = try? String(contentsOf: appFile, encoding: .utf8)
        else {
            Issue.record("BonkApp.swift not found")
            return
        }

        let missing = modelTypes.filter { !contents.contains("\($0).self") }.sorted()
        #expect(missing.isEmpty,
                """
                These @Model types are not in BonkApp's Schema literal, so a migration \
                would drop their tables:
                \(missing.joined(separator: ", "))
                """)
    }
}
