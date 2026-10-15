import Foundation
import Testing
@testable import Bonk

/// The arithmetic behind the toolbar transfer ring.
///
/// The view is trivial; this is not. Three things can go wrong that a screenshot
/// would not reveal, and all three produce a ring that *looks* like information:
///
///  1. A transfer with an unknown size cannot be summed into a percentage, and
///     dividing the known ones anyway produces a confident wrong number.
///  2. A finished or failed transfer must stop counting, or the ring never fills.
///  3. Progress past 100% — the final chunk can land before the completion flag —
///     must be clamped, because `Circle.trim(from:to:)` beyond 1 draws a stray arc.
@Suite("SFTP transfer aggregate — honest progress for the toolbar ring")
struct SFTPTransferAggregateTests {
    private func transfer(
        total: UInt64?,
        done: UInt64,
        direction: SFTPTransferDirection = .download,
        complete: Bool = false,
        cancelled: Bool = false,
        error: String? = nil
    ) -> SFTPTransfer {
        SFTPTransfer(
            id: UUID(), filename: UUID().uuidString, direction: direction,
            totalBytes: total, transferredBytes: done,
            isComplete: complete, isCancelled: cancelled, error: error
        )
    }

    @Test("nothing active means no ring and no fraction")
    func noTransfersIsInactive() {
        let aggregate = SFTPTransferAggregate(transfers: [])
        #expect(!aggregate.isActive)
        #expect(!aggregate.isDeterminate)
        #expect(aggregate.download.fraction == nil)
        #expect(aggregate.upload.fraction == nil)
    }

    @Test("finished, cancelled and failed transfers are excluded")
    func inactiveStatesAreExcluded() {
        let aggregate = SFTPTransferAggregate(transfers: [
            transfer(total: 100, done: 100, complete: true),
            transfer(total: 100, done: 40, cancelled: true),
            transfer(total: 100, done: 10, error: "connection lost"),
        ])
        #expect(!aggregate.isActive,
                "a finished, cancelled and a failed transfer leave nothing running")
    }

    @Test("summing several transfers is by total bytes, not by averaging fractions")
    func aggregatesByBytesNotByAveraging() {
        // 100/100 and 0/900. Averaging the fractions gives 0.5, which is badly
        // wrong: 100 of 1000 bytes is 10%.
        let aggregate = SFTPTransferAggregate(transfers: [
            transfer(total: 100, done: 100),
            transfer(total: 900, done: 0),
        ])
        #expect(aggregate.activeCount == 2)
        #expect(aggregate.download.count == 2)
        #expect(aggregate.download.totalBytes == 1000)
        #expect(aggregate.download.transferredBytes == 100)
        #expect((aggregate.download.fraction ?? 0) - 0.10 < 1e-9,
                "aggregate fraction must be bytes-weighted; got \(aggregate.download.fraction ?? -1)")
    }

    @Test("an unknown-size transfer makes the ring indeterminate rather than guessing")
    func unknownSizeIsIndeterminate() {
        let aggregate = SFTPTransferAggregate(transfers: [
            transfer(total: 100, done: 50),
            transfer(total: nil, done: 0),
        ])
        #expect(aggregate.isActive)
        #expect(!aggregate.isDeterminate,
                "a total cannot be computed when one transfer has no size")
        #expect(aggregate.download.fraction == nil,
                "showing a percentage here would be inventing the denominator")
    }

    @Test("a zero total is treated as unknown, not as an instant completion")
    func zeroTotalIsNotComplete() {
        // `SFTPTransfer`'s convenience init maps 0 to nil, but a transfer can still
        // arrive with totalBytes == 0. Dividing by it would be a NaN, and a NaN
        // fraction makes `Circle.trim` undefined.
        let aggregate = SFTPTransferAggregate(transfers: [
            transfer(total: 0, done: 0),
        ])
        #expect(aggregate.isActive)
        #expect(aggregate.download.fraction == nil)
        #expect(!aggregate.isDeterminate)
    }

    @Test("uploads and downloads are counted separately, never merged")
    func directionsAreNotMerged() {
        // A slow 10 GB download alongside a finished-ish small upload. Merged, the
        // ring would sit near 99% and look stalled; split, each arc is honest.
        let aggregate = SFTPTransferAggregate(transfers: [
            transfer(total: 10_000, done: 1_000, direction: .download),
            transfer(total: 100, done: 90, direction: .upload),
        ])
        #expect(aggregate.download.count == 1)
        #expect(aggregate.upload.count == 1)
        #expect((aggregate.download.fraction ?? 0) - 0.10 < 1e-9,
                "download arc must reflect downloads only; got \(String(describing: aggregate.download.fraction))")
        #expect((aggregate.upload.fraction ?? 0) - 0.90 < 1e-9,
                "upload arc must reflect uploads only; got \(String(describing: aggregate.upload.fraction))")
    }

    @Test("progress beyond the total is clamped to 1")
    func overProgressIsClamped() {
        // The final chunk can be counted before `isComplete` is set.
        let aggregate = SFTPTransferAggregate(transfers: [
            transfer(total: 100, done: 137),
        ])
        #expect(aggregate.download.fraction == 1.0,
                "over-reported bytes must clamp, not wrap; got \(String(describing: aggregate.download.fraction))")
    }
}
/// The toolbar cannot observe the transfers array, so the service must announce
/// every change.
///
/// ## The defect this gates
///
/// Progress ticks mutate `SFTPTransfer` *elements* — `fraction`,
/// `transferredBytes` — which do not change the `transfers` property itself. An
/// observer reading `transfers` therefore saw the initial `append` and then
/// nothing: the ring froze at the start of a transfer and the popover was rebuilt
/// from a stale snapshot. The user saw a dead indicator for a whole transfer.
///
/// `transferTick` is bumped on every mutation precisely so that watching one
/// scalar is sufficient. This test fails if any path mutates transfer state
/// without bumping it.
@Suite("SFTP transfer tick — the toolbar has something to observe")
struct SFTPTransferTickTests {
    @MainActor
    @Test("progress mutation bumps the tick the toolbar observes")
    func progressMutationBumpsTick() async throws {
        let service = SFTPService()
        let before = service.transferTick
        let id = UUID()
        service.transfers.append(
            SFTPTransfer(
                id: id, filename: "a.bin", direction: .download,
                totalBytes: 100, transferredBytes: 0, isComplete: false
            )
        )
        #expect(service.transferTick != before, "adding a transfer must be observable")

        // The element write goes through the service's own update path, which is
        // what every production transfer site uses. Writing
        // `transfers[idx].fraction` directly is the bug this replaced, and it is
        // deliberately not what is exercised here.
        let mid = service.transferTick
        service.updateTransfer(id) { $0.transferredBytes = 40 }
        #expect(service.transferTick != mid,
                "a progress update must bump the tick; the ring freezes without it")
        #expect(service.transfers.first?.transferredBytes == 40,
                "the update must actually apply")

        let late = service.transferTick
        service.updateTransfer(id) { $0.isComplete = true }
        #expect(service.transferTick != late, "completion must bump the tick too")
    }
}

/// A transfer must always leave the list.
///
/// ## Why this exists
///
/// Removal was scheduled only on the success and error paths. A cancelled
/// transfer was flagged `isCancelled` and then left in the list forever at
/// whatever fraction it had reached — visibly, a row stuck at 100% that never
/// went away, and reopening the SFTP window showed the same stuck row.
@Suite("SFTP transfer lifecycle — completed and cancelled transfers both leave")
struct SFTPTransferLifecycleTests {
    @MainActor
    @Test("a cancelled transfer is excluded from the active ring")
    func cancelledTransferIsNotActive() async throws {
        let service = SFTPService()
        let id = UUID()
        service.transfers.append(
            SFTPTransfer(
                id: id, filename: "big.iso", direction: .upload,
                totalBytes: 1_000, transferredBytes: 1_000, isComplete: false
            )
        )
        #expect(SFTPTransferAggregate(transfers: service.transfers).isActive,
                "a running transfer at 100% is still active until it is marked done")

        service.updateTransfer(id) { $0.isCancelled = true }
        let after = SFTPTransferAggregate(transfers: service.transfers)
        #expect(!after.isActive,
                "a cancelled transfer must not keep the ring spinning")
        #expect(after.activeCount == 0)
    }
}

/// "Finished" must be distinguishable from "never started" — and from "hung".
///
/// ## The defect this gates
///
/// The ring had no completion state. A finished upload and an idle toolbar both
/// have zero active transfers, so they looked identical, and the ring kept
/// showing whatever progress arc it last drew. A user watching it could not tell
/// whether the transfer had completed or stalled, and waited.
@Suite("SFTP transfer aggregate — completion is its own state")
struct SFTPTransferCompletionStateTests {
    @MainActor
    @Test("a finished transfer reports completed, not idle and not active")
    func finishedIsItsOwnState() {
        let service = SFTPService()
        let id = UUID()
        service.transfers.append(
            SFTPTransfer(
                id: id, filename: "movie.mkv", direction: .upload,
                totalBytes: 2_000, transferredBytes: 2_000, isComplete: false
            )
        )
        let running = SFTPTransferAggregate(transfers: service.transfers)
        #expect(running.isActive)
        #expect(!running.hasJustCompleted)

        service.updateTransfer(id) { $0.isComplete = true }
        let finished = SFTPTransferAggregate(transfers: service.transfers)
        #expect(!finished.isActive, "nothing is running any more")
        #expect(finished.hasJustCompleted,
                "a finished transfer must be visible as finished, not as idle")
        #expect(finished.completedCount == 1)
    }

    @MainActor
    @Test("removal returns the ring to idle")
    func removalReturnsToIdle() {
        let service = SFTPService()
        let id = UUID()
        service.transfers.append(
            SFTPTransfer(
                id: id, filename: "a.bin", direction: .download,
                totalBytes: 10, transferredBytes: 10, isComplete: true
            )
        )
        #expect(SFTPTransferAggregate(transfers: service.transfers).hasJustCompleted)

        service.transfers.removeAll { $0.id == id }
        let idle = SFTPTransferAggregate(transfers: service.transfers)
        #expect(!idle.isActive)
        #expect(!idle.hasJustCompleted, "after removal there is nothing left to report")
    }

    @MainActor
    @Test("a failed transfer is not counted as completed")
    func failureIsNotCompletion() {
        let service = SFTPService()
        service.transfers.append(
            SFTPTransfer(
                id: UUID(), filename: "broken.iso", direction: .upload,
                totalBytes: 100, transferredBytes: 40,
                isComplete: false, error: "connection lost"
            )
        )
        let aggregate = SFTPTransferAggregate(transfers: service.transfers)
        #expect(!aggregate.isActive)
        #expect(!aggregate.hasJustCompleted,
                "a failure must not show as a success tick")
    }
}

/// Ticks must be observable from a main-actor consumer.
///
/// ## The defect this gates
///
/// The toolbar watched `transferTick` with `withObservationTracking`. Its callback
/// closure is **nonisolated** while `SFTPService` is `@MainActor`, so the
/// observation was registered from a context that does not own the state. It fired
/// unreliably and the toolbar item froze the moment a transfer started — which is
/// what "it dies as soon as I upload" meant.
///
/// The replacement is a stream: yielding *into* the actor, so the consumer resumes
/// on the main actor with the state already valid. This test asserts that contract
/// — one yield per mutation, delivered to a main-actor consumer — which is the
/// property the old mechanism could not provide.
@Suite("SFTP transfer stream — main-actor consumers see every tick")
struct SFTPTransferStreamTests {
    @MainActor
    @Test("each mutation delivers exactly one yield to a main-actor consumer")
    func streamDeliversEveryTick() async throws {
        let service = SFTPService()
        let stream = service.transferUpdates
        let received = Counter()

        // Consumer resumes on the main actor, the same way the toolbar's does.
        let consumer = Task { @MainActor in
            for await _ in stream {
                received.increment()
            }
        }

        let id = UUID()
        service.transfers.append(
            SFTPTransfer(
                id: id, filename: "a.bin", direction: .upload,
                totalBytes: 100, transferredBytes: 0, isComplete: false
            )
        )
        for _ in 0 ..< 5 {
            service.updateTransfer(id) { $0.fraction = 0.5 }
        }

        // Drain: the consumer resumes on MainActor, so give it a turn.
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()

        #expect(received.value >= 6,
                """
                expected at least 6 yields (1 append + 5 updates), got \(received.value). \
                A drop here is a consumer that will freeze mid-transfer.
                """)
        #expect(received.value <= service.transferTick,
                """
                \(received.value) yields for \(service.transferTick) mutations: the stream \
                is amplifying, which is the other failure mode — unbounded work per tick.
                """)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func increment() { lock.withLock { n += 1 } }
    }
}

/// The ring's two real failure modes, gated at the layer that actually decides them.
///
/// ## Why these are not written against `SFTPTransferAggregate` alone
///
/// The completion gate added earlier passed against the aggregate's own initialiser,
/// and the bug was still live in the app. `SFTPTransferRingItemController` filtered
/// finished transfers out *before* constructing the aggregate, so every transfer
/// arrived already stripped of the state the completion display depends on. A test
/// on the constructor could not see that, because it handed the constructor the
/// finished transfer that production never gave it.
///
/// These gates therefore go through `SFTPRingState.aggregate(services:)` — the
/// production decision — and through `SFTPRingUpdater.makeConsumerTasks`, the
/// production consumption loop.
@Suite("SFTP toolbar ring — production decision layer")
@MainActor
struct SFTPRingProductionLayerTests {
    // MARK: - Defect A: completion was filtered out before the aggregate saw it

    @Test("a finished transfer survives the production aggregation as completed")
    func completionSurvivesProductionAggregation() {
        let service = SFTPService()
        let id = UUID()
        service.transfers.append(
            SFTPTransfer(
                id: id, filename: "movie.mkv", direction: .upload,
                totalBytes: 2_000, transferredBytes: 2_000, isComplete: false
            )
        )

        let running = SFTPRingState.aggregate(services: [service])
        #expect(running.isActive)
        #expect(!running.hasJustCompleted)

        service.updateTransfer(id) { $0.isComplete = true }

        // This is the exact expression the toolbar evaluates. If the filter that
        // used to live here comes back, `hasJustCompleted` goes false and the
        // completion state silently disappears — which is the reported bug.
        let finished = SFTPRingState.aggregate(services: [service])
        #expect(finished.hasJustCompleted,
                """
                the production aggregation dropped the finished transfer. The ring \
                would go back to idle instead of showing the tick, and the user \
                cannot tell a finished upload from a stalled one.
                """)
        #expect(finished.completedCount == 1)
        #expect(!finished.isActive)
    }

    @Test("a failed transfer never renders as a success tick")
    func failureIsNeverSuccess() {
        let service = SFTPService()
        service.transfers.append(
            SFTPTransfer(
                id: UUID(), filename: "broken.iso", direction: .download,
                totalBytes: 100, transferredBytes: 40,
                isComplete: false, error: "connection lost"
            )
        )
        let aggregate = SFTPRingState.aggregate(services: [service])
        #expect(!aggregate.hasJustCompleted)
        #expect(!aggregate.isActive)
    }

    // MARK: - Defect B: one repaint per tick saturated the main actor

    @Test("a tick burst repaints at a bounded rate and still delivers the final state")
    func burstIsCoalescedAndFinalStateArrives() async throws {
        let service = SFTPService()
        let id = UUID()
        service.transfers.append(
            SFTPTransfer(
                id: id, filename: "big.bin", direction: .upload,
                totalBytes: 100_000, transferredBytes: 0, isComplete: false
            )
        )

        let updater = SFTPRingUpdater()
        let seen = Recorder()
        let tasks = updater.makeConsumerTasks(services: [service]) {
            // Exactly what the toolbar paints from.
            seen.record(SFTPRingState.aggregate(services: [service]))
        }

        // A burst in the shape a fast local transfer produces.
        for step in 1 ... 5_000 {
            service.updateTransfer(id) { $0.transferredBytes = UInt64(step) }
        }

        // Well past the repaint interval; the drain must not still be working
        // through the backlog.
        try await Task.sleep(for: .milliseconds(400))
        let afterBurst = seen.count

        #expect(afterBurst > 0, "the ring never repainted at all")
        #expect(afterBurst <= 20,
                """
                \\(afterBurst) repaints for 5000 ticks in 400ms. Uncoalesced this is \
                ~12500/s of full aggregation on the main actor, which saturates it and \
                leaves the whole toolbar unresponsive — the "it goes dead" symptom.
                """)

        // Drain really is keeping up: the backlog must not still be queued.
        service.updateTransfer(id) { $0.isComplete = true }
        try await Task.sleep(for: .milliseconds(400))
        for task in tasks { task.cancel() }

        #expect(seen.last?.hasJustCompleted == true,
                """
                the final state never reached the ring. Either draining is throttled \
                (so the backlog outlives the transfer) or the last tick was dropped. \
                A finished transfer with no completion tick is indistinguishable \
                from a stalled one.
                """)
        #expect(seen.count > afterBurst, "the completion repaint never happened")
    }

    private final class Recorder {
        private(set) var snapshots: [SFTPTransferAggregate] = []
        var count: Int { snapshots.count }
        var last: SFTPTransferAggregate? { snapshots.last }
        func record(_ aggregate: SFTPTransferAggregate) { snapshots.append(aggregate) }
    }
}

/// Draining must keep up with the tick rate.
///
/// ## Why this gate exists separately
///
/// The first version of the burst test asserted repaint rate and final state, and
/// it stayed green when the drain was throttled — the error this implementation was
/// written to avoid. The reason is worth recording: the painter reads *live* state
/// from `SFTPService`, so a completely stalled drain still paints a perfectly
/// current ring. Repaint-count assertions cannot see drain lag at all.
///
/// It is still a live bug. The drain is what carries the *wake-up*, so a backlog
/// delays the moment a finished transfer is noticed. Asserted here against the
/// drained count, with a window short enough that a throttled drain cannot fake it.
@Suite("SFTP toolbar ring — drain keeps up")
@MainActor
struct SFTPRingDrainRateTests {
    @Test("a 5000-tick burst is drained, not queued behind a throttle")
    func drainKeepsUpWithTheTickRate() async throws {
        let service = SFTPService()
        let id = UUID()
        service.transfers.append(
            SFTPTransfer(
                id: id, filename: "big.bin", direction: .upload,
                totalBytes: 100_000, transferredBytes: 0, isComplete: false
            )
        )

        let updater = SFTPRingUpdater()
        let tasks = updater.makeConsumerTasks(services: [service]) {}

        let burst = 5_000
        for step in 1 ... burst {
            service.updateTransfer(id) { $0.transferredBytes = UInt64(step) }
        }

        // Well under the time a per-element throttle would need (5000 x 100ms).
        try await Task.sleep(for: .milliseconds(500))
        for task in tasks { task.cancel() }

        #expect(updater.drainedCount >= burst,
                """
                \\(updater.drainedCount) of \\(burst) ticks drained in 500ms. The drain \
                has been throttled to the repaint interval, so it now takes about \
                \\(Double(burst) * 100 / 1000, format: .number.precision(.fractionLength(0)))s \
                to clear this burst. The ring still *looks* current, because the \
                painter reads live state — but a completed transfer waits behind the \
                backlog to be noticed, which is the freeze this was meant to avoid.
                """)
    }
}
