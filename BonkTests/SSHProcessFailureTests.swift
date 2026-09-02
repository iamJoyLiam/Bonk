import XCTest
@testable import Bonk

final class SSHProcessFailureTests: XCTestCase {
    func testAuthentication() {
        let tail = "Permission denied (publickey,password)."
        let f = SSHProcessFailureClassifier.classify(tail: tail, stderr: "", terminationStatus: 255, wasUserClosed: false)
        XCTAssertEqual(f, .authentication(tail))
    }
    func testAllAuthOptionsFailed() {
        let tail = "Connection failed: allAuthenticationOptionsFailed"
        let f = SSHProcessFailureClassifier.classify(tail: tail, stderr: "", terminationStatus: 255, wasUserClosed: false)
        XCTAssertEqual(f?.isAuthentication, true)
    }
    func testHostKey() {
        let tail = "Host key verification failed."
        let f = SSHProcessFailureClassifier.classify(tail: tail, stderr: "", terminationStatus: 255, wasUserClosed: false)
        XCTAssertEqual(f, .hostKey(tail))
    }
    func testNetwork() {
        let tail = "Connection refused"
        let f = SSHProcessFailureClassifier.classify(tail: tail, stderr: "", terminationStatus: 255, wasUserClosed: false)
        XCTAssertEqual(f, .network(tail))
    }
    func testForwarding() {
        let tail = "channel 0: open failed: administratively prohibited: open failed"
        let f = SSHProcessFailureClassifier.classify(tail: tail, stderr: "", terminationStatus: 255, wasUserClosed: false)
        XCTAssertEqual(f, .forwarding(tail))
    }
    func testCancelled() {
        let f = SSHProcessFailureClassifier.classify(tail: "", stderr: "", terminationStatus: 0, wasUserClosed: true)
        XCTAssertEqual(f, .cancelled)
    }
    func testCancelledSignal() {
        let f = SSHProcessFailureClassifier.classify(tail: "some", stderr: "", terminationStatus: 130, wasUserClosed: false)
        // 130 is treated as unknown unless tail matches, but wasUserClosed false so not cancelled
        XCTAssertNotEqual(f, .cancelled)
    }
    func testChineseNotClassifiedByProcess() {
        let tail = "认证失败：用户名或密码错误"
        let f = SSHProcessFailureClassifier.classify(tail: tail, stderr: "", terminationStatus: 255, wasUserClosed: false)
        // Process classifier is EN-only; SessionManager.isAuthFailure handles Chinese after explain
        XCTAssertNil(f)
    }
}
