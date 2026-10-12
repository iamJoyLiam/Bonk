//
//  CanonicalHostKeyStore.swift
//  Bonk
//
//  The single canonical host-key trust store: compare-and-set over
//  `HostKeyRecord`, with a real durability boundary.
//
//  ## Why this is not `UserDefaults`
//
//  `PersistentHostKeyStore` writes `UserDefaults.standard` and calls the write
//  done. That is not a durability guarantee: the value is buffered and the
//  process can exit before it reaches disk. Trust that is not durable is not
//  trust — and worse, a *lost* trust record reads as `absent`, which is the one
//  state that re-authorises a first contact. `UserDefaults.set` is therefore
//  insufficient proof that a record was committed, and calling `synchronize()`
//  would not change that.
//
//  So commits go to a file, written the way a durable write has to be written:
//  mutate a temporary file in the *same directory*, `fsync` it, `rename` it
//  over the target (atomic on POSIX), then `fsync` the *directory* so the rename
//  itself is durable. Only after that does the call return success.
//
//  ## Why the lock is process-wide, not instance-wide
//
//  Two `CanonicalHostKeyStore` instances in one process can address the same
//  file — production already constructs a store per session, and tests construct
//  them freely. An actor or a per-instance lock would serialise each instance
//  against itself while leaving two instances free to interleave
//  read-compare-write on the same bytes, which is precisely the race that lets a
//  second first-contact overwrite the first. The lock is therefore a static
//  registry keyed by resolved file path, so all instances sharing a file share
//  one mutex.
//

import Darwin
import Foundation

/// Error type for the canonical store, kept separate from trust outcomes so a
/// caller can never confuse "the write failed" with "the key differed".
public struct CanonicalHostKeyStoreError: Error, LocalizedError, Equatable {
    public enum Reason: String, Equatable, Sendable {
        case couldNotLock
        case couldNotEncode
        case couldNotWriteTemporary
        case couldNotSyncTemporary
        case couldNotReplace
        case couldNotSyncDirectory
        case couldNotRead
        case missingDirectory
    }

    public let reason: Reason
    public init(_ reason: Reason) { self.reason = reason }

    public var errorDescription: String? {
        "canonical host-key store: \(reason.rawValue)"
    }
}

/// The on-disk shape.
///
/// Two maps rather than one dictionary of mixed values, so a fingerprint-only
/// pin and a full record cannot be confused for one another by a type error, a
/// decoding default, or a future reader.
struct CanonicalHostKeyFile: Codable, Sendable {
    /// `host:port` → full record.
    var records: [String: HostKeyRecord] = [:]
    /// `host:port` → fingerprint-only pin, predating key material.
    var legacyFingerprints: [String: SSHHostFingerprint] = [:]
}

/// A `flock(2)` mutex on a sidecar lock file, spanning the whole CAS transaction.
///
/// ## Why a sidecar file
///
/// The obvious approach — lock the data file itself — cannot work here. Every
/// commit ends in `rename(2)` over that path, which replaces the inode, so the
/// lock would be held on an inode no future opener can see. Two processes would
/// each lock their own private copy of a file that is no longer in use, and the
/// read-compare-write would interleave exactly as before.
///
/// A separate `canonical-host-keys.lock` never gets renamed, so its inode is
/// stable and every participant locks the *same* object.
///
/// ## Why it is re-entrant against `NSLock`
///
/// `flock` is advisory and per-open-file-description, and is not re-entrant: the
/// same process locking the same descriptor twice deadlocks on some platforms and
/// silently succeeds on others. Since one process may hold several store
/// instances over the same path, a thread-level `NSRecursiveLock` guards the
/// in-process case and only the outermost acquisition takes `flock`. The
/// in-process lock is still needed on its own — it serialises threads, which
/// `flock` alone does not do, since separate `open()` calls in one process get
/// separate descriptions.
final class CanonicalHostKeyFileLock {
    private let recursive: NSRecursiveLock = NSRecursiveLock()
    private let descriptor: Int32
    private var depth = 0

    /// Stable sidecar path derived from the data file's path.
    static func lockURL(for dataURL: URL) -> URL {
        dataURL
            .deletingLastPathComponent()
            .appendingPathComponent("canonical-host-keys.lock")
    }

    init(lockURL: URL) throws {
        descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw CanonicalHostKeyStoreError(.couldNotLock)
        }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// Run `body` holding the lock. Returns nil if the lock could not be taken.
    func withLock<T>(_ body: () throws -> T) rethrows -> T? {
        recursive.lock()
        defer { recursive.unlock() }

        if depth == 0 {
            // No timeout: a concurrent writer holding the lock is doing work we
            // must not race, and giving up would turn contention into a spurious
            // failure. Writes are short.
            while flock(descriptor, LOCK_EX) != 0 {
                if errno == EINTR { continue }
                return nil
            }
        }
        depth += 1
        defer {
            depth -= 1
            if depth == 0 { _ = flock(descriptor, LOCK_UN) }
        }
        return try body()
    }
}

/// Durable, cross-process-serialised canonical host-key store.
///
/// Not an `SSHHostKeyStore`: that protocol's `saveFingerprint` overwrites
/// unconditionally, which is the behaviour being replaced.
public final class CanonicalHostKeyStore: @unchecked Sendable {
    /// One lock per resolved data-file path, shared by every instance in this
    /// process addressing it. Process-wide in coordination terms; the real
    /// cross-process guarantee comes from the `flock` in `CanonicalHostKeyFileLock`.
    private static let lockRegistry = NSLock()
    private nonisolated(unsafe) static var locks: [String: NSRecursiveLock] = [:]

    private static func inProcessLock(for path: String) -> NSRecursiveLock {
        lockRegistry.lock()
        defer { lockRegistry.unlock() }
        if let existing = locks[path] { return existing }
        let created = NSRecursiveLock()
        locks[path] = created
        return created
    }

    /// Where the record set lives. Injectable so tests can use a temp directory.
    public let fileURL: URL

    /// The cross-process mutex guarding every mutation of `fileURL`.
    public let lockURL: URL

    private let fileLock: CanonicalHostKeyFileLock

    /// - Throws: if the sidecar lock file cannot be created. Failing here is
    ///   deliberate: a store that cannot lock must not appear to work.
    public init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        self.lockURL = CanonicalHostKeyFileLock.lockURL(for: fileURL)
        self.fileLock = try CanonicalHostKeyFileLock(lockURL: self.lockURL)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        // Sorted keys so a rewrite that changes nothing produces identical bytes,
        // which keeps "did the file change?" honest when diagnosing.
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Default production location, beside the other app-private SSH state.
    public static func defaultFileURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Bonk", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("host_key_records.json")
    }

    // MARK: - Lookup

    /// Run `body` under both locks, in the order every path uses.
    ///
    /// The in-process recursive lock is taken first, then `flock`. `flock` alone
    /// does not serialise threads in one process — separate `open()` calls yield
    /// separate file descriptions — and taking them in one fixed order is what
    /// keeps this safe to nest.
    @discardableResult
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let inProcess = Self.inProcessLock(for: fileURL.path)
        inProcess.lock()
        defer { inProcess.unlock() }
        guard let value = try fileLock.withLock(body) else {
            throw CanonicalHostKeyStoreError(.couldNotLock)
        }
        return value
    }

    /// Read one host's trust state. Four states, never a bare optional.
    public func lookup(host: String, port: UInt16) throws -> HostKeyLookup {
        try locked {
            let stored = try readUnlocked()
            return Self.classify(
                stored.records[Self.key(host, port)],
                legacy: stored.legacyFingerprints[Self.key(host, port)]
            )
        }
    }

    /// Shared classification, so `lookup` and the CAS paths cannot disagree
    /// about what counts as a usable record.
    static func classify(
        _ record: HostKeyRecord?,
        legacy: SSHHostFingerprint?
    ) -> HostKeyLookup {
        if let record {
            if let reason = HostKeyBlob.validate(record) {
                return .invalidOrCorrupt(reason: reason)
            }
            return .complete(record)
        }
        if let legacy { return .legacyFingerprintOnly(legacy) }
        return .absent
    }

    private static func key(_ host: String, _ port: UInt16) -> String {
        "\(host.lowercased()):\(port)"
    }

    // MARK: - Compare-and-set

    /// Establish or confirm trust, never replacing a different key.
    ///
    /// The whole read-compare-write transaction runs under the shared file lock,
    /// and success is reported only after the commit is durable.
    @discardableResult
    public func recordIfAbsentOrMatching(
        host: String,
        port: UInt16,
        candidate: HostKeyRecord
    ) throws -> HostKeyCASOutcome {
        if let invalid = HostKeyBlob.validate(candidate) {
            // A candidate that disagrees with itself is never written; treating
            // it as a conflict keeps the caller from learning "persisted".
            return .conflict
        }
        return try locked {
            var stored = try readUnlocked()
            let recordKey = Self.key(host, port)

            if let existing = stored.records[recordKey] {
                // A record that fails validation must not be overwritten: doing
                // so would let a corrupt store be healed by whichever key arrived
                // next.
                guard HostKeyBlob.validate(existing) == nil else { return .conflict }
                guard existing == candidate else { return .conflict }
                return .alreadyMatching
            }

            // A legacy fingerprint is trust. A candidate that agrees with it may
            // proceed; one that does not must not replace it.
            if let legacy = stored.legacyFingerprints[recordKey] {
                guard candidate.fingerprint == legacy else { return .conflict }
                // Fall through: the pin matches, so establishing the full record
                // is a completion of existing trust, not a new decision.
            }

            stored.records[recordKey] = candidate
            do {
                try commitUnlocked(stored)
            } catch {
                return .persistenceFailure
            }
            return .inserted
        }
    }

    /// Add key material to a fingerprint-only record, conditionally.
    ///
    /// Every condition is re-checked inside the same locked transaction, because
    /// the value read by the caller may be stale by the time this runs.
    @discardableResult
    public func backfillKeyMaterial(
        host: String,
        port: UInt16,
        expectedLegacyFingerprint: SSHHostFingerprint,
        candidate: HostKeyRecord
    ) throws -> HostKeyBackfillOutcome {
        if let invalid = HostKeyBlob.validate(candidate) {
            _ = invalid
            return .conflict
        }
        // The candidate must be the key the legacy pin described.
        guard candidate.fingerprint == expectedLegacyFingerprint else { return .conflict }

        return try locked {
            var stored = try readUnlocked()
            let recordKey = Self.key(host, port)

            // Already migrated by someone else. Only "already complete" if it is
            // genuinely the same key.
            if let existing = stored.records[recordKey] {
                guard HostKeyBlob.validate(existing) == nil else { return .conflict }
                return existing == candidate ? .alreadyComplete : .conflict
            }

            // Still legacy-only? The pin must be present *and* unchanged since
            // read.
            guard let currentLegacy = stored.legacyFingerprints[recordKey] else { return .conflict }
            guard currentLegacy == expectedLegacyFingerprint else { return .conflict }

            stored.records[recordKey] = candidate
            do {
                try commitUnlocked(stored)
            } catch {
                return .persistenceFailure
            }
            return .backfilled
        }
    }

    // MARK: - Legacy import

    /// Seed the legacy pins from the pre-existing `com.bonk.hostKeys` data.
    ///
    /// Additive and non-destructive: legacy entries are retained alongside any
    /// records, never deleted, so a rollback cannot lose the trust that predates
    /// this store.
    public func importLegacyFingerprints(_ fingerprints: [String: SSHHostFingerprint]) throws {
        guard !fingerprints.isEmpty else { return }
        try locked {
            var stored = try readUnlocked()
            var changed = false
            for (composite, fingerprint) in fingerprints {
                // Legacy keys look "host:port".
                let parts = composite.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let port = UInt16(parts[1]) else { continue }
                let key = Self.key(String(parts[0]), port)
                // Never displace a full record with a bare fingerprint.
                if stored.records[key] == nil, stored.legacyFingerprints[key] == nil {
                    stored.legacyFingerprints[key] = fingerprint
                    changed = true
                }
            }
            guard changed else { return }
            try commitUnlocked(stored)
        }
    }

    // MARK: - Durable IO

    private func readUnlocked() throws -> CanonicalHostKeyFile {
        guard fileManager.fileExists(atPath: fileURL.path) else { return CanonicalHostKeyFile() }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CanonicalHostKeyStoreError(.couldNotRead)
        }
        guard !data.isEmpty else { return CanonicalHostKeyFile() }
        do {
            return try decoder.decode(CanonicalHostKeyFile.self, from: data)
        } catch {
            // A file we cannot parse is not an empty file: it is unknown trust.
            // Surfacing it as empty would re-authorise first contact.
            throw CanonicalHostKeyStoreError(.couldNotRead)
        }
    }

    /// Write durably: temp in the same directory, fsync, atomic rename, fsync
    /// the directory. Returns only once the rename is itself on disk.
    private func commitUnlocked(_ stored: CanonicalHostKeyFile) throws {
        let data: Data
        do {
            data = try encoder.encode(stored)
        } catch {
            throw CanonicalHostKeyStoreError(.couldNotEncode)
        }

        let directory = fileURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: directory.path) else {
            throw CanonicalHostKeyStoreError(.missingDirectory)
        }

        // Same directory, so rename(2) stays within one filesystem and is atomic.
        let temporary = directory.appendingPathComponent(
            ".host_key_records.\(UUID().uuidString).tmp"
        )

        guard fileManager.createFile(atPath: temporary.path, contents: data) else {
            throw CanonicalHostKeyStoreError(.couldNotWriteTemporary)
        }
        guard let handle = try? FileHandle(forWritingTo: temporary) else {
            try? fileManager.removeItem(at: temporary)
            throw CanonicalHostKeyStoreError(.couldNotWriteTemporary)
        }
        let synced = (try? handle.synchronize()) != nil
        try? handle.close()
        guard synced else {
            try? fileManager.removeItem(at: temporary)
            throw CanonicalHostKeyStoreError(.couldNotSyncTemporary)
        }
        _ = chmod(temporary.path, mode_t(0o600))

        // Replace atomically.
        guard rename(temporary.path, fileURL.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw CanonicalHostKeyStoreError(.couldNotReplace)
        }

        // fsync the directory so the rename is durable, not just the bytes.
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else {
            throw CanonicalHostKeyStoreError(.couldNotSyncDirectory)
        }
        let directorySynced = fsync(directoryFD) == 0
        close(directoryFD)
        guard directorySynced else {
            throw CanonicalHostKeyStoreError(.couldNotSyncDirectory)
        }
    }
}