import XCTest
@testable import Bonk

final class SessionRecordingTests: XCTestCase {
    func testRecordingCreatesAsciicast() async throws {
        let svc = SessionRecordingService.shared
        let tab = UUID(), pane = UUID()
        let rec = try await svc.start(host: "testhost", tabID: tab, paneID: pane, cols: 80, rows: 24)
        await svc.recordOutput(paneID: pane, text: "hello\n")
        await svc.recordInput(paneID: pane, bytes: Array("ls\n".utf8)[...])
        await svc.recordOutput(paneID: pane, text: "world\n")
        await svc.stop(paneID: pane)
        let content = try String(contentsOf: rec.url, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 3) // header + 2 outputs + 1 input
        let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(header["version"] as? Int, 2)
        XCTAssertEqual(header["width"] as? Int, 80)
        // second line should be [time, "o", "hello\n"]
        let ev1 = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [Any]
        XCTAssertEqual(ev1[1] as? String, "o")
        XCTAssertEqual(ev1[2] as? String, "hello\n")
        // cleanup
        try? await svc.delete(url: rec.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rec.url.path))
    }

    func testRecordingCap500MB() async throws {
        let svc = SessionRecordingService.shared
        let tab = UUID(), pane = UUID()
        let rec = try await svc.start(host: "h", tabID: tab, paneID: pane)
        // write a lot but not actually 500MB, just verify cap check doesn't crash
        for _ in 0..<10 { await svc.recordOutput(paneID: pane, text: String(repeating: "a", count: 1024)) }
        await svc.stop(paneID: pane)
        try? await svc.delete(url: rec.url)
    }
}
