//
//  TerminalEngineFlushMutationTests.swift
//  BonkTests
//
//  `flush` iterates the consumer table while calling into arbitrary consumer
//  code. That code can subscribe, unsubscribe, and push more bytes — so the
//  iteration is re-entrant and the table can change underneath it.
//
//  The tests below pin down what a flush *means* while that happens. They are
//  written against the real engine and the real `TerminalConsumer` protocol, not
//  against a copy of the loop, because the question is what the production
//  iteration does when a consumer misbehaves.
//

import AppKit
import Testing
import Foundation
@testable import Bonk

@Suite("Terminal Engine Flush Mutation Tests")
@MainActor
struct TerminalEngineFlushMutationTests {

    // MARK: - Doubles

    /// A consumer that mutates the engine from inside `receive`.
    ///
    /// This is the shape of the real hazard: a terminal view can be torn down,
    /// or a new one created, while it is being handed a batch.
    final class MutatingConsumer: TerminalConsumer {
        private(set) var received: [String] = []
        private(set) var consumeCalls: Int = 0
        private(set) var dropCalls: Int = 0
        /// Runs after the text is recorded, so reentrancy is observable.
        var onReceive: ((String) -> Void)?

        init(onReceive: ((String) -> Void)? = nil) {
            self.onReceive = onReceive
        }

        func receive(_ text: String) {
            received.append(text)
            onReceive?(text)
        }

        func didConsume(bytes: Int) { consumeCalls += 1 }
        func didDrop(bytes: Int) { dropCalls += 1 }
    }

    private func makeEngine(
        watermark: Watermark = .default
    ) -> (TerminalEngine, TestDisplaySource) {
        let display = TestDisplaySource()
        return (TerminalEngine(displaySource: display, watermark: watermark), display)
    }

    /// Text large enough to force an immediate flush inside `push`, which is
    /// what makes a re-entrant flush possible.
    private static var forceFlushText: String { String(repeating: "F", count: 17_000) }

    // MARK: - The snapshot boundary

    /// A consumer that subscribes mid-flush does not receive the in-flight
    /// batch.
    ///
    /// Those bytes arrived before it existed. Handing them over would show a
    /// freshly created view history it never asked for, and makes delivery
    /// depend on where the mutation landed in the table.
    @Test("A consumer subscribed during a flush does not receive that batch")
    func subscriberDuringFlushMissesTheBatch() async throws {
        let (engine, _) = makeEngine()
        let lateID = UUID()
        let first = MutatingConsumer()
        let late = MutatingConsumer()

        engine.subscribe(UUID(), consumer: first)
        engine.push("batch-1")
        first.onReceive = { [weak engine] _ in
            engine?.subscribe(lateID, consumer: late)
        }
        engine.flushForTest()

        #expect(first.received == ["batch-1"])
        #expect(late.received.isEmpty,
                "a consumer that appeared during the flush must not receive that batch")

        // It is live for the next batch, which is the point of subscribing.
        engine.push("batch-2")
        engine.flushForTest()
        #expect(late.received == ["batch-2"],
                "a mid-flush subscriber must be live for subsequent batches")
    }

    /// Every consumer present when the flush started gets the batch, even if a
    /// peer unsubscribed another one while the flush was running.
    @Test("Unsubscribing a peer during a flush does not skip it")
    func unsubscribeDuringFlushDoesNotSkip() async throws {
        let (engine, _) = makeEngine()
        let victimID = UUID()
        let mutating = MutatingConsumer()
        let victim = MutatingConsumer()
        let bystander = MutatingConsumer()

        engine.subscribe(UUID(), consumer: mutating)
        engine.subscribe(victimID, consumer: victim)
        engine.subscribe(UUID(), consumer: bystander)

        engine.push("payload")
        mutating.onReceive = { [weak engine] _ in
            engine?.unsubscribe(victimID)
        }
        engine.flushForTest()

        #expect(mutating.received == ["payload"])
        #expect(bystander.received == ["payload"],
                "an unrelated consumer must not be skipped by another's removal")
        // The victim was in the snapshot, so it is still delivered to if alive.
        #expect(victim.received == ["payload"],
                "a consumer removed mid-flush must not silently lose its bytes")
    }

    /// Byte accounting stays exact when the table changes mid-flush.
    ///
    /// This is the invariant that actually matters downstream: a consumer that
    /// is visited zero times never acknowledges its bytes, so the pending-byte
    /// watermark is computed from a total that no longer matches reality.
    @Test("Byte acknowledgements stay exact when consumers mutate the table")
    func byteAccountingSurvivesMutation() async throws {
        let (engine, _) = makeEngine()
        let victimID = UUID()
        let mutating = MutatingConsumer()
        let victim = MutatingConsumer()
        let bystander = MutatingConsumer()

        engine.subscribe(UUID(), consumer: mutating)
        engine.subscribe(victimID, consumer: victim)
        engine.subscribe(UUID(), consumer: bystander)

        engine.push("payload")
        mutating.onReceive = { [weak engine] _ in
            engine?.unsubscribe(victimID)
            engine?.subscribe(UUID(), consumer: MutatingConsumer())
        }
        engine.flushForTest()

        for consumer in [mutating, victim, bystander] {
            #expect(consumer.consumeCalls == 1,
                    "each snapshot member acknowledges exactly once")
            #expect(consumer.received.count == 1, "no consumer sees the batch twice")
        }
    }

    // MARK: - Re-entrancy

    /// A consumer that pushes more bytes during a flush does not reorder what
    /// other consumers see.
    ///
    /// `push` can force an immediate flush, so a consumer that echoes output
    /// re-enters `flush` while the outer flush is still walking the table. The
    /// consumer that has not been reached yet would otherwise receive the
    /// *newer* batch first and the batch it was waiting for second — terminal
    /// output arriving backwards.
    @Test("A re-entrant flush does not reorder batches per consumer")
    func reentrantFlushDoesNotReorder() async throws {
        let (engine, _) = makeEngine()
        var pushedDuringFlush = false
        let a = MutatingConsumer()
        let b = MutatingConsumer()

        // Whichever consumer is reached first triggers the nested flush, so the
        // other one is provably still unvisited when it happens.
        let trigger: (String) -> Void = { [weak engine] _ in
            guard let engine, !pushedDuringFlush else { return }
            pushedDuringFlush = true
            engine.push(Self.forceFlushText)
        }
        a.onReceive = trigger
        b.onReceive = trigger

        engine.subscribe(UUID(), consumer: a)
        engine.subscribe(UUID(), consumer: b)
        engine.push("first-batch")
        engine.flushForTest()

        #expect(pushedDuringFlush, "the test did not actually re-enter flush")
        for (name, consumer) in [("a", a), ("b", b)] {
            #expect(consumer.received.count == 2,
                    "consumer \(name) should see both batches, saw \(consumer.received.count)")
            guard consumer.received.count == 2 else { continue }
            #expect(consumer.received[0] == "first-batch",
                    """
                    consumer \(name) received the later batch first: \
                    \(consumer.received.map { String($0.prefix(11)) })
                    """)
        }
        // Nothing left in flight: every pushed byte was delivered, and the
        // engine's own accounting agrees.
        #expect(engine.pendingBytesForTest == 0,
                "the drain must leave no unflushed bytes behind")
        // The mid-flush push here was large enough to be drained inline, so
        // there is no scheduled flush coming to tidy up after us. `dirty` must
        // already be accurate: it may only mean "there is unflushed data".
        #expect(!engine.dirtyForTest,
                "a fully drained engine must not still report itself dirty")
    }

    /// Bytes pushed during a flush are not lost, duplicated, or left pending.
    ///
    /// A *small* mid-flush push is deliberately not delivered inline — it goes
    /// through the engine's normal coalescing path and lands on the next
    /// scheduled flush. What must hold is that it arrives exactly once and in
    /// order, and that nothing is left pending afterwards.
    @Test("A re-entrant flush leaves no bytes behind or doubled")
    func reentrantFlushBalancesBytes() async throws {
        let (engine, display) = makeEngine()
        var pushed = false
        let consumer = MutatingConsumer()
        consumer.onReceive = { [weak engine] _ in
            guard let engine, !pushed else { return }
            pushed = true
            engine.push("tail")
        }
        engine.subscribe(UUID(), consumer: consumer)

        engine.push("head")
        engine.flushForTest()
        #expect(pushed, "the test did not re-enter flush")
        #expect(consumer.received == ["head"], "only the in-flight batch is inline")
        #expect(engine.dirtyForTest,
                "bytes pushed mid-flush are still pending, so the engine must say so")

        // Let the coalescing path deliver the mid-flush bytes.
        display.tick()
        try? await Task.sleep(for: .milliseconds(60))

        #expect(consumer.received == ["head", "tail"],
                "batches must arrive once each, in order; saw \(consumer.received)")
        #expect(engine.pendingBytesForTest == 0, "no bytes left pending")
        #expect(!engine.dirtyForTest,
                "once drained, `dirty` must mean empty — a stale flag misreports the buffer")
    }

    /// A deallocated consumer is skipped without disturbing the rest.
    ///
    /// The table holds weak references, so a view torn down before its next
    /// flush must not be messaged.
    @Test("A released consumer is skipped without affecting the others")
    func releasedConsumerIsSkipped() async throws {
        let (engine, _) = makeEngine()
        let survivor = MutatingConsumer()
        engine.subscribe(UUID(), consumer: survivor)
        do {
            let transient = MutatingConsumer()
            engine.subscribe(UUID(), consumer: transient)
        } // `transient` released here

        engine.push("payload")
        engine.flushForTest()

        #expect(survivor.received == ["payload"],
                "a released consumer must not stop the flush")
    }
}
