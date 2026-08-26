//
//  TerminalEngineTests.swift
//  BonkTests
//
//  Headless seam test: Engine coalesces to display tick.
//

import XCTest
@testable import Bonk

@MainActor
final class TerminalEngineTests: XCTestCase {

    func testCoalescesMultiplePushesToOneTick() async {
        let display = TestDisplaySource()
        let engine = TerminalEngine(displaySource: display)
        let consumer = HeadlessTerminalConsumer()
        let id = UUID()
        engine.subscribe(id, consumer: consumer)

        engine.push("hello ")
        engine.push("world")
        // No tick yet → no receive
        XCTAssertTrue(consumer.received.isEmpty)
        display.tick()
        // Allow MainActor flush (tick task → flush)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(consumer.joined, "hello world")
    }

    func testImmediateFlushOnLargeBuffer() async {
        let display = TestDisplaySource()
        let engine = TerminalEngine(displaySource: display)
        let consumer = HeadlessTerminalConsumer()
        engine.subscribe(UUID(), consumer: consumer)

        let big = String(repeating: "x", count: 17000)
        engine.push(big)
        // Should flush immediately without waiting for tick (>=16K)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(consumer.received.isEmpty)
        XCTAssertEqual(consumer.joined.count, 17000)
    }

    func testWatermarkDropsNewest() async {
        let display = TestDisplaySource()
        let watermark = Watermark(high: 100, low: 50)
        let engine = TerminalEngine(displaySource: display, watermark: watermark)
        let consumer = HeadlessTerminalConsumer()
        engine.subscribe(UUID(), consumer: consumer)

        engine.push(String(repeating: "a", count: 90)) // pending 90
        engine.push(String(repeating: "b", count: 20)) // 110 > high 100 → drop
        display.tick()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(consumer.joined, String(repeating: "a", count: 90))
        XCTAssertEqual(engine.droppedBytesForTest, 20)
    }

    func testBareCRHeldUntilNextPush() async {
        let display = TestDisplaySource()
        let engine = TerminalEngine(displaySource: display)
        let consumer = HeadlessTerminalConsumer()
        engine.subscribe(UUID(), consumer: consumer)

        // Bare CR should stay in same batch as following text (Docker Compose \r case).
        // Push foo\r then bar without intermediate tick → should coalesce to one receive.
        engine.push("foo\r")
        engine.push("bar")
        display.tick()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(consumer.joined, "foo\rbar")
        XCTAssertEqual(consumer.received.count, 1, "bare CR and following text should be in same batch")
    }

    func testSubscribeUnsubscribe() async {
        let display = TestDisplaySource()
        let engine = TerminalEngine(displaySource: display)
        let c1 = HeadlessTerminalConsumer()
        let c2 = HeadlessTerminalConsumer()
        let id1 = UUID(), id2 = UUID()
        engine.subscribe(id1, consumer: c1)
        engine.subscribe(id2, consumer: c2)

        engine.push("hi")
        engine.unsubscribe(id1)
        display.tick()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(c1.received.isEmpty)
        XCTAssertEqual(c2.joined, "hi")
    }

    func testResizeCoalesced() async {
        let display = TestDisplaySource()
        let engine = TerminalEngine(displaySource: display)
        var resizes: [(Int, Int)] = []
        engine.onResize = { cols, rows in resizes.append((cols, rows)) }

        engine.resize(cols: 80, rows: 24)
        engine.resize(cols: 100, rows: 30)
        engine.resize(cols: 120, rows: 40)
        try? await Task.sleep(for: .milliseconds(40))
        // Should coalesce to last value only (debounced 16ms)
        XCTAssertEqual(resizes.count, 1)
        XCTAssertEqual(resizes.first?.0, 120)
        XCTAssertEqual(resizes.first?.1, 40)
    }
}
