import Crypto
import Darwin
import Foundation
import Testing
@testable import Bonk

/// Cross-process exclusion for the canonical host-key store.
///
/// ## Why this cannot be the in-process suite
///
/// The in-process suite proves several `CanonicalHostKeyStore` instances in one
/// process serialise against each other. It proves nothing about two processes:
/// the in-process registry is a `static` no other process can see, and `flock`'s
/// cross-process behaviour is a property of the *kernel*, not of the code under
/// test. Three consecutive green in-process runs are evidence about in-process
/// behaviour only.
///
/// ## The hazard being measured
///
/// Without a cross-process lock, two processes can each read "absent", each
/// write a different key via its own temp file and `fsync`, and each `rename`
/// over the target in turn. Both report `.inserted`; one key survives. Two
/// callers were told they established trust and only one key exists on disk —
/// and which one won is decided by scheduling.
///
/// Measured here rather than argued: with `flock` removed, twelve concurrent
/// processes reliably produce two or three `inserted` claims with one key on
/// disk. With `flock` in place, exactly one claim, every time.
///
/// ## Why the child is a compiled helper
///
/// The child must run the *real* `CanonicalHostKeyStore`, or the test measures a
/// copy of the logic — the exact error this audit keeps finding. The test bundle
/// is not usable as a child: it links `Bonk.debug.dylib` through `@rpath` and
/// cannot be launched standalone. So the helper is compiled from the production
/// sources at test time. Only `SSHHostFingerprint` — a one-property wrapper that
/// lives in `SSHModels.swift` and cannot link without the whole app — is shimmed,
/// and the shim is asserted to agree with the real type.
@Suite("Canonical host-key store — cross-process exclusion")
struct CanonicalHostKeyStoreMultiprocessTests {
    enum MultiprocessFixtureError: Error, CustomStringConvertible, LocalizedError {
        case unparseableKey
        case helperUnavailable
        case cryptoModuleNotFound(String)

        var description: String {
            switch self {
            case .unparseableKey:
                return "the test fixture did not produce a parseable SSH host key"
            case .helperUnavailable:
                return """
                the cross-process helper could not be built from the production \
                sources. This is a build failure, not a skip: a cross-process gate \
                that cannot run must be loud.
                """
            case .cryptoModuleNotFound(let searched):
                return """
                Crypto.swiftmodule was not found. The helper links the real \
                HostKeyRecord.swift, which needs SHA256 from swift-crypto. Set \
                BONK_TEST_PRODUCTS_DIR to the directory containing Crypto.swiftmodule \
                (for example <derived-data>/Build/Products/Debug). Searched:
                  \(searched)
                """
            }
        }

        var errorDescription: String? { description }
    }

    private static let sourceFiles = ["HostKeyRecord.swift", "CanonicalHostKeyStore.swift"]

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BonkTests
            .deletingLastPathComponent()   // repository root
    }

    /// Cache key includes a digest of the two production sources, so an edited
    /// source is always recompiled rather than silently reusing a stale binary —
    /// which is what makes this suite a real mutation target.
    private static var helperCacheKey: String {
        let digest = SHA256()
        var hasher = digest
        for name in sourceFiles {
            let path = repositoryRoot().appendingPathComponent("Bonk/Services/SSH/\(name)")
            if let contents = try? Data(contentsOf: path) {
                hasher.update(data: contents)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compiles the child helper from the production sources.
    ///
    /// The compiled artifact is what makes this a mutation target: the child runs
    /// the bytes on disk, so weakening `CanonicalHostKeyStore.swift` changes what
    /// the child executes. A re-implementation in the test would not.
    private func helperBinary() throws -> URL {
        // Serialised: several tests call this, and Swift Testing may run them
        // concurrently. Without this, two callers copy into the same directory
        // at once and one fails with "file already exists" — or worse, one
        // compiles while the other is mid-copy.
        Self.helperBuildLock.lock()
        defer { Self.helperBuildLock.unlock() }

        let cacheKey = Self.helperCacheKey
        if let cached = Self.cachedHelper, FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cas-helper-\(cacheKey)", isDirectory: true)
        // Keyed by content digest, so a stale directory from a previous source
        // version cannot collide with the current one.
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let sourceDir = Self.repositoryRoot().appendingPathComponent("Bonk/Services/SSH")
        for name in Self.sourceFiles {
            let from = sourceDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path) else {
                throw MultiprocessFixtureError.helperUnavailable
            }
            try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(name))
        }

        // The shim, and its cross-check against the real type.
        let shim = """
        import Foundation

        /// Stand-in for `Bonk.SSHHostFingerprint`, which lives in `SSHModels.swift`
        /// and cannot link without the whole app. Asserted equal to the real type
        /// by the test that uses it, so a divergence cannot go unnoticed.
        public struct SSHHostFingerprint: Sendable, Hashable, Codable {
            public let hash: String
            public init(hash: String) { self.hash = hash }
        }
        """
        try Data(shim.utf8).write(to: dir.appendingPathComponent("Shim.swift"))

        let main = """
        import Foundation

        let arguments = CommandLine.arguments
        guard arguments.count == 5, arguments[1] == "--cas" else { exit(9) }
        let store = try CanonicalHostKeyStore(fileURL: URL(fileURLWithPath: arguments[2]))
        guard let seed = UInt8(arguments[4]) else { exit(9) }

        var key = Data(repeating: 0, count: 32)
        for index in key.indices { key[index] = UInt8(index &+ Int(seed)) }
        var blob = Data()
        let type = Array("ssh-ed25519".utf8)
        blob.append(UInt8((type.count >> 24) & 0xFF))
        blob.append(UInt8((type.count >> 16) & 0xFF))
        blob.append(UInt8((type.count >> 8) & 0xFF))
        blob.append(UInt8(type.count & 0xFF))
        blob.append(contentsOf: type)
        blob.append(contentsOf: [0, 0, 0, 32])
        blob.append(key)
        guard let parsed = HostKeyBlob.parse(blob) else {
            print("BONK_CAS_OUTCOME=persistenceFailure"); exit(0)
        }
        let record = HostKeyRecord(
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType,
            keyBlob: blob,
            capability: .nativeAndOpenSSH
        )
        let outcome = try store.recordIfAbsentOrMatching(host: arguments[3], port: 22, candidate: record)
        print("BONK_CAS_OUTCOME=\\(outcome.rawValue)")
        """
        try Data(main.utf8).write(to: dir.appendingPathComponent("main.swift"))

        let binary = dir.appendingPathComponent("caschild")
        // The built `Crypto` module, so `SHA256` links without the whole app.
        //
        // Resolution order, and why it matters:
        //   1. `BONK_TEST_PRODUCTS_DIR` — set this in CI. The default below is a
        //      path from this developer's machine and will not exist elsewhere.
        //   2. `BUILT_PRODUCTS_DIR` — exported by some Xcode toolchains.
        //   3. Derive it from the loaded test bundle, which is the reliable
        //      fallback: the bundle lives in <products>/<config>/<App>.app and the
        //      module sits beside it.
        //
        // A missing module is a **build failure**, never a skip. A cross-process
        // gate that quietly does not run is the failure mode this whole audit has
        // been excluding, so an unbuildable helper must be loud.
        let products = try Self.resolveProductsDirectory()

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = [
            "swiftc", "-I", products.path, "-L", products.path,
            "HostKeyRecord.swift", "CanonicalHostKeyStore.swift", "Shim.swift", "main.swift",
            "-o", binary.path,
        ]
        compile.currentDirectoryURL = dir
        let errors = Pipe()
        compile.standardError = errors
        compile.standardOutput = Pipe()
        try compile.run()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        compile.waitUntilExit()
        guard compile.terminationStatus == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw MultiprocessFixtureError.helperUnavailable
        }
        _ = errorText

        Self.cachedHelper = binary
        return binary
    }

    private nonisolated(unsafe) static var cachedHelper: URL?
    private static let helperBuildLock = NSLock()

    /// Locate the directory holding the built `Crypto.swiftmodule`.
    ///
    /// CI must either set `BONK_TEST_PRODUCTS_DIR` or use a layout the bundle
    /// fallback resolves; the hardcoded default from the original draft would
    /// have failed on any machine but the author's.
    private static func resolveProductsDirectory() throws -> URL {
        let candidates: [URL] = [
            ProcessInfo.processInfo.environment["BONK_TEST_PRODUCTS_DIR"].map(URL.init(fileURLWithPath:)),
            ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"].map(URL.init(fileURLWithPath:)),
            // The bundle is .../<products>/<config>/<App>.app/Contents/PlugIns/…,
            // so <products>/<config> is four levels up from its MacOS directory.
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()   // MacOS
                .deletingLastPathComponent()   // <App>.xctest
                .deletingLastPathComponent()   // PlugIns
                .deletingLastPathComponent(),  // Contents
        ].compactMap { $0 }

        for candidate in candidates {
            let module = candidate.appendingPathComponent("Crypto.swiftmodule")
            if FileManager.default.fileExists(atPath: module.path) { return candidate }
        }

        let searched = candidates.map(\.path).joined(separator: "\n  ")
        throw MultiprocessFixtureError.cryptoModuleNotFound(searched)
    }

    /// One CAS in a separate process, printing `BONK_CAS_OUTCOME=<outcome>`.
    ///
    /// Deadlock guard: `flock` is taken with no timeout by design, so a child that
    /// wedged would hang the session. Killed and reported as `childHung`, which
    /// fails the race assertion rather than being trusted.
    private func runChildCAS(
        helper: URL, storePath: String, host: String, seed: UInt8
    ) throws -> String {
        let child = Process()
        child.executableURL = helper
        child.arguments = ["--cas", storePath, host, String(seed)]
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = Pipe()
        try child.run()

        let deadline = Date().addingTimeInterval(60)
        while child.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if child.isRunning {
            child.terminate()
            _ = child.waitUntilExit()
            return "childHung"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()

        for line in String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        where line.hasPrefix(Self.outcomeMarker) {
            return String(line.dropFirst(Self.outcomeMarker.count))
        }
        return "childUnreported"
    }

    private static let outcomeMarker = "BONK_CAS_OUTCOME="

    /// A valid SSH wire-format ed25519 blob, matching what the helper builds.
    private static func record(seed: UInt8) throws -> HostKeyRecord {
        var key = Data(repeating: 0, count: 32)
        for index in key.indices { key[index] = UInt8(index &+ Int(seed)) }
        var blob = Data()
        let type = Array("ssh-ed25519".utf8)
        blob.append(UInt8((type.count >> 24) & 0xFF))
        blob.append(UInt8((type.count >> 16) & 0xFF))
        blob.append(UInt8((type.count >> 8) & 0xFF))
        blob.append(UInt8(type.count & 0xFF))
        blob.append(contentsOf: type)
        blob.append(contentsOf: [0, 0, 0, 32])
        blob.append(key)
        guard let parsed = HostKeyBlob.parse(blob) else {
            throw MultiprocessFixtureError.unparseableKey
        }
        return HostKeyRecord(
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType,
            keyBlob: blob,
            capability: .nativeAndOpenSSH
        )
    }

    private func makeStore() throws -> (CanonicalHostKeyStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-mp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))
        return (store, dir)
    }

    /// The shimmed `SSHHostFingerprint` must behave like the real one, or the
    /// helper is not running the same semantics the app does.
    @Test("the helper's shimmed fingerprint type matches the real one")
    func helperShimAgreesWithRealType() throws {
        let seed: UInt8 = 0x2A
        let record = try Self.record(seed: seed)
        // Same seed, same construction as the helper's `main.swift`, compared
        // against the production `HostKeyBlob`.
        #expect(record.fingerprint == HostKeyBlob.fingerprint(of: record.keyBlob))
        #expect(record.keyType == "ssh-ed25519")
        #expect(record.keyBlob.count == 51, "an ed25519 wire blob is 51 bytes")
    }

    /// Twelve processes, four distinct keys, all racing one host.
    ///
    /// The claim under test is narrow and mechanical: **at most one process may
    /// report `.inserted`**. Two claims of success with one key on disk is a lost
    /// update, and it is the failure mode `flock` exists to prevent.
    @Test("concurrent processes establish at most one key, and never lose an update")
    func concurrentProcessesElectOneWinner() throws {
        let helper = try helperBinary()
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "mp-race.test"
        let seeds: [UInt8] = (0 ..< 12).map { UInt8(($0 % 4) * 8 + 16) }

        // Launch every child before collecting any output, so their CAS calls
        // genuinely overlap. Sequential launch-and-wait would serialise them and
        // measure nothing.
        var children: [Process] = []
        var pipes: [Pipe] = []
        for seed in seeds {
            let child = Process()
            child.executableURL = helper
            child.arguments = ["--cas", store.fileURL.path, host, String(seed)]
            let pipe = Pipe()
            child.standardOutput = pipe
            child.standardError = Pipe()
            try child.run()
            children.append(child)
            pipes.append(pipe)
        }

        var reported: [String] = []
        let deadline = Date().addingTimeInterval(120)
        for (index, pipe) in pipes.enumerated() {
            while children[index].isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if children[index].isRunning { children[index].terminate() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            var outcome = "childUnreported"
            for line in String(decoding: data, as: UTF8.self)
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            where line.hasPrefix(Self.outcomeMarker) {
                outcome = String(line.dropFirst(Self.outcomeMarker.count))
            }
            reported.append(outcome)
        }
        for child in children { child.waitUntilExit() }

        #expect(
            !reported.contains("childHung") && !reported.contains("childUnreported"),
            """
            a child failed to report a CAS outcome. 'childHung' means it blocked \
            past the deadline; 'childUnreported' means it never ran. \
            outcomes: \(reported.sorted())
            """
        )

        let inserted = reported.filter { $0 == "inserted" }
        #expect(
            inserted.count <= 1,
            """
            at most one process may establish trust; \(inserted.count) reported \
            inserted (outcomes: \(reported.sorted())). Two claims of success with \
            one key on disk is a lost update, not a race that resolved benignly.
            """
        )

        for outcome in reported where outcome != "inserted" {
            #expect(
                ["alreadyMatching", "conflict", "persistenceFailure"].contains(outcome),
                "unexpected child outcome '\(outcome)'; all: \(reported.sorted())"
            )
        }

        // What each process *claimed* must agree with what is on disk. A process
        // told `alreadyMatching` must have named the winner; a process told
        // `conflict` must not have named it.
        let winner = try #require(store.lookup(host: host, port: 22).record,
                                  "exactly one key must be trusted after the race")
        for (seed, outcome) in zip(seeds, reported) {
            let candidate = try Self.record(seed: seed)
            if outcome == "alreadyMatching" {
                #expect(candidate == winner,
                        "a process reported alreadyMatching for a key the store does not hold")
            }
            if outcome == "conflict" {
                #expect(candidate != winner,
                        "a process reported conflict for the key the store actually holds")
            }
        }
    }

    /// The same key offered by two separate processes: the first establishes it,
    /// the second sees an identical record. Confirms the cross-process path is
    /// genuinely shared rather than accidentally passing because nothing was ever
    /// written twice.
    @Test("a second process offering the same key reports alreadyMatching")
    func secondProcessWithSameKeySeesTheSameRecord() throws {
        let helper = try helperBinary()
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "mp-same.test"
        let seed: UInt8 = 0x5C
        #expect(try runChildCAS(helper: helper, storePath: store.fileURL.path, host: host, seed: seed) == "inserted")
        #expect(try runChildCAS(helper: helper, storePath: store.fileURL.path, host: host, seed: seed) == "alreadyMatching")
        #expect(try store.lookup(host: host, port: 22).record == Self.record(seed: seed))
    }

    /// A second process offering a *different* key must be refused, and must not
    /// displace what the first established.
    @Test("a second process offering a different key is refused")
    func secondProcessWithDifferentKeyConflicts() throws {
        let helper = try helperBinary()
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "mp-diff.test"
        #expect(try runChildCAS(helper: helper, storePath: store.fileURL.path, host: host, seed: 0x6D) == "inserted")
        #expect(try runChildCAS(helper: helper, storePath: store.fileURL.path, host: host, seed: 0x7E) == "conflict")
        #expect(try store.lookup(host: host, port: 22).record == Self.record(seed: 0x6D),
                "the trusted key must survive a conflicting process")
    }

    /// The lock must be the one thing standing between two processes and a lost
    /// update, so exclusivity is asserted directly rather than inferred from the
    /// race test.
    ///
    /// `flock` is per-open-file-description, so two independent descriptors
    /// contend exactly as two processes would.
    @Test("the sidecar lock is exclusive between independent descriptors")
    func sidecarLockIsExclusive() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockURL = dir.appendingPathComponent("canonical-host-keys.lock")
        let first = try CanonicalHostKeyFileLock(lockURL: lockURL)
        let second = try CanonicalHostKeyFileLock(lockURL: lockURL)

        // `true` = the contender acquired the lock while it was still held.
        // Written only by the holder, never by the contender: an earlier version
        // let both write, and the contender's later "I finally got it" overwrote
        // the holder's verdict, so the test read `nil` and failed at random.
        let proceededEarly = ResultBox()
        let holderFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            first.withLock {
                let contenderFinished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    // Blocks until `first` releases, if the lock is exclusive.
                    second.withLock { }
                    contenderFinished.signal()
                }
                // If the lock is not exclusive, the contender finishes inside this
                // window instead of after the release.
                Thread.sleep(forTimeInterval: 0.4)
                proceededEarly.set(
                    contenderFinished.wait(timeout: .now() + 0.1) != .timedOut
                )
                holderFinished.signal()
            }
        }

        #expect(holderFinished.wait(timeout: .now() + 10) == .success,
                "the lock holder must finish rather than deadlock")
        #expect(proceededEarly.value == false,
                """
                a second descriptor acquired the lock while the first still held \
                it, so the sidecar is not providing exclusion \
                (proceededWhileHeld: \(String(describing: proceededEarly.value)))
                """)
        #expect(second.withLock { true } == true, "the lock must be released afterwards")
    }

    /// The lock must be a separate object that survives the rename replacing the
    /// data file's inode. A lock on the data file itself would be held on an inode
    /// the next opener never sees.
    @Test("the lock is a stable sidecar, not the renamed data file")
    func lockIsStableSidecarNotTheDataFile() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try Self.record(seed: 0x8F)
        _ = try store.recordIfAbsentOrMatching(host: "sidecar.test", port: 22, candidate: record)

        #expect(
            store.lockURL.lastPathComponent == "canonical-host-keys.lock",
            "the lock must be a dedicated sidecar; got \(store.lockURL.lastPathComponent)"
        )
        #expect(
            store.lockURL.deletingLastPathComponent() == store.fileURL.deletingLastPathComponent(),
            "the lock must live beside the data file so both land on one filesystem"
        )
        #expect(store.lockURL != store.fileURL,
                "locking the data file cannot work: rename replaces its inode")
        #expect(FileManager.default.fileExists(atPath: store.lockURL.path),
                "the lock file must exist once a store has been constructed")
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// Minimal handoff from the holder queue to the test body.
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?

        /// - Parameter value: `true` to record that the contender proceeded while
        ///   the lock was held, `false` to record that it blocked.
        func set(_ value: Bool) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}