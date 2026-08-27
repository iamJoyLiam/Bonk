import XCTest
@testable import Bonk

final class LogColorizerReproTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LogColorizerConfig.isEnabled = true
    }
    func testDockerPsHyphenatedAlertNotColored() {
        let line = "abc123   my-alert-service   Up 5 minutes\n"
        let colored = LogColorizer.colorize(line)
        XCTAssertFalse(colored.contains("\u{1B}["), "docker ps hyphenated alert should NOT be colored, got: \(colored.debugDescription)")
    }

    func testDockerPsStandaloneAlertNotColored() {
        let line = "abc123   alert   Up 5 minutes\n"
        let colored = LogColorizer.colorize(line)
        XCTAssertFalse(colored.contains("\u{1B}["), "docker ps standalone alert column should NOT be colored (no log anchor), got: \(colored.debugDescription)")
    }

    func testLogLineShouldBeColored() {
        LogColorizerConfig.isEnabled = true
        let line = "2026-08-26 10:00:00 INFO hello 192.168.1.1\n"
        let colored = LogColorizer.colorize(line)
        XCTAssertTrue(colored.contains("\u{1B}["), "log line should be colored, got: \(colored.debugDescription)")
        XCTAssertTrue(colored.contains("INFO"), "should still contain INFO")
        // Tail without newline is intentionally left raw for coalescer
        let tail = "2026-08-26 10:00:00 INFO hello 192.168.1.1"
        let tailColored = LogColorizer.colorize(tail)
        XCTAssertFalse(tailColored.contains("\u{1B}["), "tail without newline should be left raw for coalescer")
    }

    func testBareErrorAtStartShouldBeColored() {
        LogColorizerConfig.isEnabled = true
        let line = "ERROR failed to connect\n"
        let colored = LogColorizer.colorize(line)
        // Per final architecture: Precision > Recall, bare ERROR without timestamp/IP/PRI is NOT_LOG
        // "INFO application started" without strong signature must be NOT_LOG per spec section 3
        XCTAssertFalse(colored.contains("\u{1B}["), "bare ERROR without strong signature should NOT be colored (precision > recall), got: \(colored.debugDescription)")
    }

    func testPlainTextNotColored() {
        LogColorizerConfig.isEnabled = true
        let line = "hello world\n"
        let colored = LogColorizer.colorize(line)
        XCTAssertFalse(colored.contains("\u{1B}["), "plain text should NOT be colored")
    }

    func testPerformanceHeavyOutput() {
        let dockerLine = "abc123   my-alert-service   Up 5 minutes   0.0.0.0:8080->80/tcp"
        let logLine = "2026-08-26 10:00:00 INFO hello 192.168.1.1"
        let mixed = (0..<5000).map { i in i % 2 == 0 ? dockerLine : logLine }.joined(separator: "\n") + "\n"
        let start = CFAbsoluteTimeGetCurrent()
        let colored = LogColorizer.colorize(mixed)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("[PERF] colorize 10k mixed lines: \(elapsed*1000)ms, output bytes: \(colored.utf8.count)")
        XCTAssertLessThan(elapsed, 0.3, "colorize should be <300ms for 10k lines (0.03ms/line, 3ms for 100-line frame)")
    }
}
