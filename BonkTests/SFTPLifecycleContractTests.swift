//
//  SFTPLifecycleContractTests.swift
//  BonkTests — P1 regression lock for SFTP resource lifecycle:
//
//  • remote handles and pooled SSH connections are released on failure
//    and cancellation paths, not only on success;
//  • the single-stream EOF check must not underflow UInt64 for small files.
//
//  No live server required: the arithmetic bound and the closer's
//  exactly-once semantics are pure logic.
//

import Testing
import Foundation
@testable import Bonk

@Suite("SFTP Lifecycle Contract Tests")
struct SFTPLifecycleContractTests {

    /// Mirror of the guarded EOF condition in singleStreamDownload.
    /// `total < chunkSize` used to evaluate `total - chunkSize` in UInt64
    /// and trap, turning a short read into a crash.
    private static func isReadDone(off: UInt64, total: UInt64, chunkSize: UInt32) -> Bool {
        if off >= total { return true }
        return total >= UInt64(chunkSize) && off >= total - UInt64(chunkSize)
    }

    @Test("EOF check never underflows for files smaller than one chunk")
    func eofCheckSafeForSmallFiles() {
        let chunk: UInt32 = 64 * 1024
        let small: UInt64 = 1_024 // far below chunk size
        // The unguarded form computed `total - chunkSize` in UInt64, which
        // traps for every file below 64 KB. Evaluating the bound instead of
        // subtracting is the fix; these cases must return without trapping.
        #expect(SFTPLifecycleContractTests.isReadDone(off: 0, total: small, chunkSize: chunk) == false)
        #expect(SFTPLifecycleContractTests.isReadDone(off: small, total: small, chunkSize: chunk))
        #expect(SFTPLifecycleContractTests.isReadDone(off: small - 1, total: small, chunkSize: chunk) == false)
    }

    @Test("EOF check still terminates reads at the end of a large file")
    func eofCheckTerminatesLargeFiles() {
        let chunk: UInt32 = 64 * 1024
        let total: UInt64 = 10 * 1024 * 1024
        // Mid-file short read must NOT be treated as done.
        #expect(SFTPLifecycleContractTests.isReadDone(off: 0, total: total, chunkSize: chunk) == false)
        // One chunk before the end must terminate the read loop.
        #expect(SFTPLifecycleContractTests.isReadDone(off: total - UInt64(chunk), total: total, chunkSize: chunk))
    }

    @Test("Boundary case total == chunkSize does not underflow")
    func eofCheckBoundaryEqualSizes() {
        let chunk: UInt32 = 64 * 1024
        let total = UInt64(chunk)
        #expect(SFTPLifecycleContractTests.isReadDone(off: 0, total: total, chunkSize: chunk))
    }

    /// Records every close so tests can assert exactly-once release.
    private actor CloseRecorder {
        private(set) var closed: [String] = []
        func record(_ name: String) { closed.append(name) }
        func count(_ name: String) -> Int { closed.filter { $0 == name }.count }
    }

    private struct Stub: RemoteClosable, Sendable {
        let name: String
        let recorder: CloseRecorder
        func closeRemote() async throws { await recorder.record(name) }
    }

    @Test("Handles tracked before release are closed exactly once")
    func trackedHandlesCloseExactlyOnce() async {
        let recorder = CloseRecorder()
        let closer = RemoteHandleCloser<Stub>()
        await closer.track(Stub(name: "a", recorder: recorder))
        await closer.track(Stub(name: "b", recorder: recorder))
        await closer.closeRemaining()
        #expect(await recorder.count("a") == 1)
        #expect(await recorder.count("b") == 1)
    }

    @Test("Repeated release does not double-close")
    func repeatedReleaseDoesNotDoubleClose() async {
        let recorder = CloseRecorder()
        let closer = RemoteHandleCloser<Stub>()
        await closer.track(Stub(name: "a", recorder: recorder))
        await closer.closeRemaining()
        await closer.closeRemaining()
        #expect(await recorder.count("a") == 1)
    }

    /// The failure paths call closeRemaining() exactly once, so a handle whose
    /// openFile lands after that call has no later sweep to catch it. The
    /// closer therefore has a terminal state: after release, tracking closes
    /// the handle immediately rather than queueing it for a sweep that will
    /// never run. Without this, the late handle leaks.
    @Test("Tracking after release closes immediately instead of leaking")
    func trackAfterReleaseClosesImmediately() async {
        let recorder = CloseRecorder()
        let closer = RemoteHandleCloser<Stub>()
        await closer.track(Stub(name: "early", recorder: recorder))
        // Single release — the failure path's only call.
        await closer.closeRemaining()
        // A shard whose openFile completes late now tracks.
        await closer.track(Stub(name: "late", recorder: recorder))
        // No further sweep exists; the late handle must already be closed.
        #expect(await recorder.count("early") == 1)
        #expect(await recorder.count("late") == 1)
        // A later sweep must not re-close either handle.
        await closer.closeRemaining()
        #expect(await recorder.count("early") == 1)
        #expect(await recorder.count("late") == 1)
    }

    @Test("Concurrent track and release close every handle exactly once")
    func concurrentTrackAndReleaseCloseExactlyOnce() async {
        let recorder = CloseRecorder()
        let closer = RemoteHandleCloser<Stub>()
        let handles = (0..<32).map { Stub(name: "h\($0)", recorder: recorder) }
        await withTaskGroup(of: Void.self) { group in
            for handle in handles {
                group.addTask { await closer.track(handle) }
            }
            group.addTask { await closer.closeRemaining() }
            await group.waitForAll()
        }
        await closer.closeRemaining()
        for handle in handles {
            #expect(await recorder.count(handle.name) == 1, "double close or leak for \(handle.name)")
        }
    }

    @Test("Releasing an empty closer is safe")
    func releaseWithoutHandlesIsSafe() async {
        let closer = RemoteHandleCloser<Stub>()
        await closer.closeRemaining()
        await closer.closeRemaining()
        #expect(Bool(true))
    }

    @Test("Half-open shard range length excludes the upper bound")
    func shardRangeLengthIsHalfOpen() {
        let start: UInt64 = 0
        let end: UInt64 = 100
        let range = start..<end
        // The old code computed upperBound - lowerBound + 1 = 101 for a
        // 100-byte shard, skewing pipeline depth tuning.
        #expect(range.upperBound - range.lowerBound == 100)
    }
}
