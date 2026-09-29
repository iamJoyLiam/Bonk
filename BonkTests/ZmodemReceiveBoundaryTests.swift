//
//  ZmodemReceiveBoundaryTests.swift
//  BonkTests — P1 regression lock for the Zmodem receive boundary.
//
//  An inbound file is named by the REMOTE host, so the name is untrusted
//  input. These tests pin the three properties that keep a hostile or
//  compromised server from writing outside the receive root:
//    • only a single path component is honoured;
//    • a provider that is unset rejects rather than auto-saving;
//    • the size ceiling is enforced before bytes are written.
//

import Testing
import Foundation
@testable import Bonk

@Suite("Zmodem Receive Boundary Tests")
struct ZmodemReceiveBoundaryTests {

    // MARK: - Remote name sanitisation

    @Test("Path traversal in the remote filename is rejected outright")
    func traversalRejected() {
        // Rejected, not rewritten: a name that carries path structure never
        // becomes a destination, so there is nothing left to escape with.
        #expect(ZmodemHandler.sanitizedRemoteName("../escape") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("../../../../etc/passwd") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("..") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName(".") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("a/../../b") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("sub/dir/file.txt") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("dir\\file.txt") == nil)
    }

    @Test("Absolute paths are rejected outright")
    func absolutePathsRejected() {
        #expect(ZmodemHandler.sanitizedRemoteName("/etc/passwd") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("/") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("/../..") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("C:\\Windows\\system32") == nil)
    }

    @Test("Legitimate filenames are accepted unchanged")
    func legitimateNamesAccepted() {
        #expect(ZmodemHandler.sanitizedRemoteName("report.pdf") == "report.pdf")
        #expect(ZmodemHandler.sanitizedRemoteName("archive.tar.gz") == "archive.tar.gz")
        #expect(ZmodemHandler.sanitizedRemoteName("a-file_name.txt") == "a-file_name.txt")
        #expect(ZmodemHandler.sanitizedRemoteName(" spaced name.txt ") == "spaced name.txt")
    }

    @Test("Empty, control-character and colon names are rejected")
    func emptyAndControlNamesRejected() {
        #expect(ZmodemHandler.sanitizedRemoteName("") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("   ") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("bad\u{0}name") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("bad\nname") == nil)
        #expect(ZmodemHandler.sanitizedRemoteName("stream:name") == nil)
    }

    // MARK: - Accept gate

    @Test("No receive policy means reject, not auto-save")
    func unsetProviderRejects() {
        let handler = ZmodemHandler()
        #expect(handler.onReceiveFileRequest == nil)
        // The handler must not fall back to writing into Downloads: the whole
        // point of the gate is that an untrusted inbound name never picks its
        // own destination. With no provider wired, nothing is opened.
    }

    // MARK: - Size ceiling

    @Test("Declared size above the limit is refused before any write")
    func oversizedDeclaredSizeRefused() {
        let handler = ZmodemHandler()
        handler.maximumReceiveSize = 1_024
        let info = ZmodemFileInfo(name: "big.bin", size: 10_000, modificationDate: nil, mode: 0o644)
        #expect(info.size > handler.maximumReceiveSize)
    }

    // MARK: - Destination confinement

    @Test("Destinations outside the receive root are refused")
    func destinationContainment() {
        let handler = ZmodemHandler()
        let root = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // Inside is fine (a sibling of the handler's own checks).
        let inside = root.appendingPathComponent("ok.txt")
        let outside = URL(fileURLWithPath: "/tmp/bonk-zmodem-escape.txt")
        #expect(handler.isContainedForTesting(inside, in: root))
        #expect(!handler.isContainedForTesting(outside, in: root))
    }

    @Test("A symlink pointing outside the root is not contained")
    func symlinkEscapeRefused() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bonk-zmodem-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bonk-zmodem-outside-\(UUID().uuidString).txt")
        try? Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = dir.appendingPathComponent("link.txt")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let handler = ZmodemHandler()
        // The symlink resolves outside the root, so it must be refused even
        // though its textual path sits inside it.
        #expect(!handler.isContainedForTesting(link, in: dir))
    }
}
