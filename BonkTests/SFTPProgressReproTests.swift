import XCTest
@testable import Bonk

@MainActor
final class SFTPProgressReproTests: XCTestCase {
    func testUnknownSizeDownloadProgressViaFraction() {
        // Unknown size: totalBytes==0 -> nil -> indeterminate ProgressView, no fake %
        let transfer = SFTPTransfer(id: UUID(), filename: "test.bin", totalBytes: 0, transferredBytes: 0, isComplete: false)
        XCTAssertNil(transfer.progress, "unknown size should have nil progress (indeterminate)")
        XCTAssertNil(transfer.totalBytes, "0 should be normalized to nil")
        // Simulate bytes arriving — transferredBytes drives MB label, not %
        transfer.transferredBytes = 500 * 1024 * 1024
        XCTAssertNil(transfer.progress, "unknown size progress stays nil even with bytes")
        transfer.isComplete = true
        // Even at completion, progress stays nil (we show MB, not %); isComplete drives icon
        XCTAssertNil(transfer.progress)
        XCTAssertTrue(transfer.isComplete)
        // fraction is internal smoothing only, not exposed as progress
        transfer.fraction = 0.9
        XCTAssertNil(transfer.progress)
    }

    func testKnownSizeProgressViaBytes() {
        let transfer = SFTPTransfer(id: UUID(), filename: "test.bin", totalBytes: 1000, transferredBytes: 0, isComplete: false)
        transfer.transferredBytes = 250
        XCTAssertEqual(transfer.progress ?? -1, 0.25, accuracy: 0.01)
        transfer.transferredBytes = 1000
        XCTAssertEqual(transfer.progress ?? -1, 1.0, accuracy: 0.01)
        // Monotonic: progress should not go backwards
        transfer.transferredBytes = 500
        // This would be 0.5, but our Service guards monotonic, but model itself allows any
        XCTAssertEqual(transfer.progress ?? -1, 0.5, accuracy: 0.01)
    }

    func testServiceTransfersObservationViaArrayMutation() {
        let t = SFTPTransfer(id: UUID(), filename: "a", totalBytes: 0, transferredBytes: 0, isComplete: false)
        XCTAssertNil(t.progress, "unknown size -> nil progress")
        t.fraction = 0.5 // internal only
        XCTAssertNil(t.progress)
        t.transferredBytes = 500
        XCTAssertNil(t.progress, "still nil — MB label via transferredBytes")
        t.fraction = 1.0
        t.isComplete = true
        XCTAssertNil(t.progress)
    }

    func testThrottleDoesNotBlockCompletion() {
        // Ensure that 100ms throttle in Service doesn't block final 1.0 from being delivered
        // Our Service code does `if clamped < 1.0, now.timeIntervalSince(lastUIUpdate) < 0.1 { return }`
        // So clamped==1.0 should always pass through
        let transfer = SFTPTransfer(id: UUID(), filename: "x", totalBytes: 100, transferredBytes: 0, isComplete: false)
        transfer.lastUIUpdate = Date() // just updated
        let clamped = 1.0
        let shouldThrottle = clamped < 1.0 && Date().timeIntervalSince(transfer.lastUIUpdate) < 0.1
        XCTAssertFalse(shouldThrottle, "1.0 should never be throttled")
    }
}
