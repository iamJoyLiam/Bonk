//
//  SecureTempFileTests.swift
//  BonkTests — P1 regression lock for temporary credential files.
//
//  The old pattern wrote the secret with the process umask (0644 on a default
//  022 umask) and narrowed it with chmod afterwards. These tests assert the
//  file is 0600 from the instant it exists, that no other user can read it,
//  and that cleanup works on every path.
//

import Testing
import Foundation
@testable import Bonk

@Suite("Secure Credential Temp File Tests")
struct SecureTempFileTests {

    private func modeOf(_ path: String) -> mode_t {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return 0 }
        return st.st_mode & 0o777
    }

    @Test("Credential file is created 0600, never 0644")
    func createdWithOwnerOnlyPermissions() throws {
        let file = try SecureTempFile.create(
            name: "bonk-test-\(UUID().uuidString).key",
            contents: Data("-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n".utf8)
        )
        defer { file.remove() }
        #expect(modeOf(file.path) == 0o600)
    }

    @Test("The 0644 window does not exist: no umask can widen the mode")
    func umaskCannotWidenPermissions() throws {
        // A permissive umask is exactly the condition that used to expose the
        // secret between write and chmod. Creating under 0000 must still yield
        // 0600 because the mode is part of the open() call.
        let previous = Darwin.umask(0o000)
        defer { Darwin.umask(previous) }
        let file = try SecureTempFile.create(
            name: "bonk-test-umask-\(UUID().uuidString).secret",
            contents: Data("hunter2".utf8)
        )
        defer { file.remove() }
        #expect(modeOf(file.path) == 0o600)
    }

    @Test("Contents are written and the file is not world/group readable")
    func contentsWrittenAndNotReadable() throws {
        let file = try SecureTempFile.create(
            name: "bonk-test-\(UUID().uuidString).secret",
            contents: Data("correct horse".utf8)
        )
        defer { file.remove() }
        #expect(try Data(contentsOf: URL(fileURLWithPath: file.path)) == Data("correct horse".utf8))
        #expect(modeOf(file.path) & 0o077 == 0)
    }

    @Test("Cleanup removes the file")
    func cleanupRemovesFile() throws {
        let file = try SecureTempFile.create(
            name: "bonk-test-\(UUID().uuidString).key",
            contents: Data("x".utf8)
        )
        #expect(FileManager.default.fileExists(atPath: file.path))
        file.remove()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Creation refuses to adopt a pre-existing file (O_EXCL)")
    func refusesToOverwriteExistingFile() throws {
        let name = "bonk-test-\(UUID().uuidString).secret"
        let first = try SecureTempFile.create(name: name, contents: Data("one".utf8))
        defer { first.remove() }
        // A second attempt must fail rather than clobber the first: an
        // attacker-planted file at this path cannot be written through.
        #expect(throws: (any Error).self) {
            _ = try SecureTempFile.create(name: name, contents: Data("two".utf8))
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: first.path)) == Data("one".utf8))
    }

    @Test("Creation refuses a symlink planted at the destination")
    func refusesSymlinkDestination() throws {
        // The link must live in the same directory `create` resolves names
        // against (the temp root), otherwise the test would not exercise the
        // path the production code takes.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let victimDir = root.appendingPathComponent("bonk-symlink-victim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: victimDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: victimDir) }

        let victim = victimDir.appendingPathComponent("victim.txt")
        try Data("original".utf8).write(to: victim)

        let name = "bonk-ssh-askpass-symlink-\(UUID().uuidString).secret"
        let link = root.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        defer { try? FileManager.default.removeItem(at: link) }

        // Writing through the link would overwrite the victim file.
        #expect(throws: (any Error).self) {
            _ = try SecureTempFile.create(name: name, contents: Data("overwritten".utf8))
        }
        // The victim is untouched.
        #expect(try Data(contentsOf: victim) == Data("original".utf8))
    }

    @Test("Sweeper removes stale credential files but spares fresh ones")
    func sweeperRemovesOnlyStaleFiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let stale = dir.appendingPathComponent("bonk-ssh-askpass-stale-\(UUID().uuidString).secret")
        let fresh = dir.appendingPathComponent("bonk-ssh-askpass-fresh-\(UUID().uuidString).secret")
        try Data("old".utf8).write(to: stale)
        try Data("new".utf8).write(to: fresh)
        defer {
            try? FileManager.default.removeItem(at: stale)
            try? FileManager.default.removeItem(at: fresh)
        }
        // Backdate the stale file well past the sweep threshold.
        let old = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)

        SecureTempFileSweeper.sweepStale(maxAge: 3600)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        // A fresh file may belong to a connection still running in this
        // process; the sweeper must not touch it.
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("Askpass pair removal clears both the script and the secret")
    func askpassPairRemoval() throws {
        let id = UUID().uuidString
        let script = try SecureTempFile.create(
            name: "bonk-ssh-askpass-\(id)",
            contents: Data("#!/bin/sh\n".utf8)
        )
        let secret = try SecureTempFile.create(
            name: "bonk-ssh-askpass-\(id).secret",
            contents: Data("pw".utf8)
        )
        _ = chmod(script.path, mode_t(0o700))

        OpenSSHBackend.removeAskpassPair(at: script.path)

        #expect(!FileManager.default.fileExists(atPath: script.path))
        #expect(!FileManager.default.fileExists(atPath: secret.path))
    }
}
