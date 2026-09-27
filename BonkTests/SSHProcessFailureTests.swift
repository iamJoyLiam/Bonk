import NIOConcurrencyHelpers
import XCTest
@testable import Bonk

private final class PTYSessionBox: @unchecked Sendable {
    var session: PTYSession?
}

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

    #if os(macOS)
        func testBoundedTextTailKeepsNewestSuffix() {
            var tail = BoundedTextTail(limit: 4)
            tail.append("ab")
            tail.append("cdef")

            XCTAssertEqual(tail.value, "cdef")
        }

        func testPTYBackpressurePreservesControlSequences() async {
            let session = PTYSession()
            let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(256))
            let consumerID = UUID()
            session.liveContinuations.withLock { $0[consumerID] = continuation }
            let consumer = Task { () -> Bool in
                for await text in stream {
                    if text.contains("\u{1B}[31m") { return true }
                }
                return false
            }

            for _ in 0 ..< 4 {
                session.yieldOutput(String(repeating: "x", count: PTYSession.maxChunkBytes))
            }
            session.yieldOutput("\u{1B}[31m")
            try? await Task.sleep(for: .milliseconds(20))
            consumer.cancel()
            let receivedControlSequence = await consumer.value
            session.close()

            XCTAssertTrue(receivedControlSequence)
        }

        func testPTYBackpressurePreservesSplitControlSequence() async {
            let session = PTYSession()
            let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(256))
            let consumerID = UUID()
            session.liveContinuations.withLock { $0[consumerID] = continuation }
            let consumer = Task { () -> Bool in
                for await text in stream {
                    if text.contains("31m") { return true }
                }
                return false
            }

            for _ in 0 ..< 4 {
                session.yieldOutput(String(repeating: "x", count: PTYSession.maxChunkBytes))
            }
            session.yieldOutput("\u{1B}[")
            session.yieldOutput("31m")
            try? await Task.sleep(for: .milliseconds(20))
            consumer.cancel()
            let receivedContinuation = await consumer.value
            session.close()

            XCTAssertTrue(receivedContinuation)
        }

        func testPTYPendingBytesDoNotLeakWhenStreamDropsChunks() {
            let session = PTYSession()
            let (_, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(4))
            let consumerID = UUID()
            session.liveContinuations.withLock { $0[consumerID] = continuation }

            // No consumer task: the stream buffer fills and drops, but pending
            // accounting must stay bounded by the buffer, not grow forever.
            for _ in 0 ..< 32 {
                session.yieldOutput(String(repeating: "x", count: PTYSession.maxChunkBytes))
            }

            XCTAssertLessThanOrEqual(session.pendingBytesForTest, 8 * PTYSession.maxChunkBytes)
            session.close()
        }

        func testPTYSessionCloseReleasesUnexpectedCloseCallback() async {
            weak var weakPTY: PTYSession?
            do {
                let pty = PTYSession()
                let ownedBox = PTYSessionBox()
                ownedBox.session = pty
                weakPTY = pty
                pty.onUnexpectedClose = { ownedBox.session = nil }
                pty.close()
            }

            await Task.yield()

            XCTAssertNil(weakPTY)
        }

        func testOpenSSHAuthPromptBufferIsBounded() {
            let responder = OpenSSHAuthPromptResponder(
                credentials: [],
                authUserHosts: [],
                allowInteractivePrompt: false,
                allowUnscopedPassword: false,
                write: { _ in }
            )

            responder.observe(Data(String(repeating: "x\n", count: 2_000).utf8))

            XCTAssertLessThanOrEqual(
                responder.promptBufferLengthForTest,
                OpenSSHAuthPromptResponder.promptBufferLimit
            )
        }

        func testOpenSSHResponderSendsHostScopedPasswordOnce() {
            let writes = NIOLockedValueBox<[String]>([])
            let responder = OpenSSHAuthPromptResponder(
                credentials: [
                    OpenSSHPasswordCredential(
                        username: "xuhaibo",
                        host: "jmp.allinmd.cn",
                        password: "secret"
                    ),
                ],
                authUserHosts: ["xuhaibo@jmp.allinmd.cn"],
                allowInteractivePrompt: false,
                allowUnscopedPassword: false,
                write: { data in writes.withLockedValue { $0.append(String(decoding: data, as: UTF8.self)) } }
            )

            responder.observe(Data("xuhaibo@jmp.allinmd.cn's password: ".utf8))
            // Second identical prompt must not re-send (maxAutoAnswers = 1).
            responder.observe(Data("xuhaibo@jmp.allinmd.cn's password: ".utf8))

            XCTAssertEqual(writes.withLockedValue { $0 }, ["secret\r"])
        }

        func testOpenSSHResponderDoesNotSendScopedPasswordToUnscopedPrompt() {
            let writes = NIOLockedValueBox<[String]>([])
            let responder = OpenSSHAuthPromptResponder(
                credentials: [
                    OpenSSHPasswordCredential(
                        username: "target",
                        host: "target.internal",
                        password: "target-secret"
                    ),
                ],
                authUserHosts: ["xuhaibo@jmp.allinmd.cn"],
                allowInteractivePrompt: false,
                allowUnscopedPassword: false,
                write: { data in writes.withLockedValue { $0.append(String(decoding: data, as: UTF8.self)) } }
            )

            responder.observe(Data("Password: ".utf8))

            XCTAssertTrue(writes.withLockedValue { $0.isEmpty })
        }

        func testOpenSSHResponderReportsManualPasswordAfterRejectionWindow() async {
            let verified = NIOLockedValueBox<[String]>([])
            let responder = OpenSSHAuthPromptResponder(
                credentials: [],
                authUserHosts: ["xuhaibo@jmp.allinmd.cn"],
                allowInteractivePrompt: false,
                allowUnscopedPassword: false,
                write: { _ in }
            )
            responder.onManualPasswordVerified = { password in verified.withLockedValue { $0.append(password) } }

            responder.observe(Data("xuhaibo@jmp.allinmd.cn's password: ".utf8))
            // Keystrokes and Enter arrive as separate writes.
            responder.observeInput(ArraySlice(Array("hunter2".utf8)))
            responder.observeInput(ArraySlice(Array("\r".utf8)))
            // Rejection inside the window must NOT report the password.
            responder.observe(Data("Permission denied, please try again.\n".utf8))
            try? await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(verified.withLockedValue { $0.isEmpty })

            // Retry and let the acceptance window elapse. Acceptance is judged
            // on the next output chunk, so one benign chunk must arrive after
            // the 2s deadline.
            responder.observe(Data("xuhaibo@jmp.allinmd.cn's password: ".utf8))
            responder.observeInput(ArraySlice(Array("hunter3".utf8)))
            responder.observeInput(ArraySlice(Array("\r".utf8)))
            try? await Task.sleep(for: .seconds(2.2))
            responder.observe(Data("\u{1B}[?2004h\r\n".utf8))

            XCTAssertEqual(verified.withLockedValue { $0 }, ["hunter3"])
        }
    #endif
}
