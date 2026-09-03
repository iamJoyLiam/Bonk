//
//  TerminalEngine.swift
//  Bonk
//
//  Deep module: single pipeline bytes → decode/normalize → one coalescer → display tick → consumers.
//  Single watermark replaces 3 lossy stages (PTY pending 256K + AsyncStream 256 + batchBuffer 16K).
//

import AppKit
import Foundation
import os

/// Watermark policy for bounded lossy terminal buffer.
struct Watermark: Sendable {
    var high: Int // drop newest when pending >= high
    var low: Int  // resume is implicit (pending < high after flush)
    static let `default` = Watermark(high: 256 * 1024, low: 64 * 1024)
}

/// Engine coalesces PTY bytes and flushes at most once per display tick.
@MainActor
final class TerminalEngine {
    private struct State {
        var buffer: String = ""
        var pendingBytes: Int = 0
        var flushScheduled: Bool = false
        var dirty: Bool = false
        var consumers: [UUID: WeakConsumer] = [:]
        var pendingResize: (Int, Int)?
        var lastResize: (Int, Int)?
        var droppedBytes: Int = 0
        var droppedChunks: Int = 0
    }

    private struct WeakConsumer {
        weak var consumer: (any TerminalConsumer)?
        let id: UUID
    }

    private var state = State()
    private let watermark: Watermark
    private let displaySource: any DisplaySource
    private var tickTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?

    /// Called on resize flush (cols, rows). Caller forwards to PTY SIGWINCH.
    var onResize: ((Int, Int) -> Void)?

    init(displaySource: any DisplaySource, watermark: Watermark = .default) {
        self.displaySource = displaySource
        self.watermark = watermark
        startTickLoop()
        observeAppActive()
    }

    deinit {
        tickTask?.cancel()
        resizeTask?.cancel()
    }

    // MARK: - Public

    /// Push raw bytes from PTY. Decoded as UTF-8. Bare CR coalesced (don't split \r without \n).
    func push(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        // PTY is source of truth — mark dirty first, display is only a render hint
        state.dirty = true
        // Fast-path single watermark: drop newest when over high
        let incoming = String(data: bytes, encoding: .utf8) ?? String(bytes: bytes.map { $0 < 0x80 ? $0 : 0x3F }, encoding: .utf8) ?? ""
        guard !incoming.isEmpty else { return }

        // Bare CR hold: if buffer tail is \r and incoming doesn't start with \n,
        // keep them together in same flush (prevents Docker Compose garble).
        let endsWithBareCR = state.buffer.utf8.last == 0x0D
            && state.buffer.utf8.count >= 1
            && incoming.utf8.first != 0x0A

        // Watermark — never drop VT control or tiny interactive echo (preserves VT semantics).
        // Bulk logs may be dropped/degraded later at decoration layer, not transport.
        let incomingBytes = incoming.utf8.count
        let isVTControl = incoming.contains("\u{1B}") // CSI/OSC/SGR — must not be split/dropped
        let isTinyInteractive = incomingBytes <= 64 && !incoming.contains("\n")
        if state.pendingBytes + incomingBytes >= watermark.high {
            if isVTControl || isTinyInteractive {
                // Force flush to make room, then allow append (exceed watermark briefly rather than corrupt VT state)
                flush()
            } else {
                state.droppedBytes += incomingBytes
                state.droppedChunks += 1
                // Drop newest bulk tail; keep VT state intact
                return
            }
        }

        state.buffer += incoming
        state.pendingBytes += incomingBytes

        // Immediate flush on large buffer (one frame worth) else schedule for next display opportunity
        if state.buffer.utf8.count >= 16384 && !endsWithBareCR {
            flush()
        } else if !endsWithBareCR {
            scheduleFlush()
        }
        // endsWithBareCR → hold until next push completes the line update
    }

    func push(_ text: String) {
        guard !text.isEmpty else { return }
        push(Data(text.utf8))
    }

    func subscribe(_ id: UUID, consumer: any TerminalConsumer) {
        state.consumers[id] = WeakConsumer(consumer: consumer, id: id)
    }

    func unsubscribe(_ id: UUID) {
        state.consumers.removeValue(forKey: id)
    }

    /// Coalesce resize to at most one SIGWINCH per display frame.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let last = state.lastResize, last.0 == cols, last.1 == rows { return }
        state.lastResize = (cols, rows)
        state.pendingResize = (cols, rows)
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self, let pending = self.state.pendingResize else { return }
            self.state.pendingResize = nil
            self.onResize?(pending.0, pending.1)
        }
    }

    /// For tests: force flush synchronously.
    func flushForTest() { flush() }

    var pendingBytesForTest: Int { state.pendingBytes }
    var droppedBytesForTest: Int { state.droppedBytes }

    // MARK: - Private

    private func startTickLoop() {
        tickTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.displaySource.ticks {
                guard !Task.isCancelled else { break }
                // Display tick is only a render hint, not permission to process PTY
                self.flushIfNeeded()
            }
        }
    }

    private func observeAppActive() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.didBecomeActive()
            }
        }
    }

    private func didBecomeActive() {
        // App returned from Cmd+Tab — flush any dirty state immediately, don't wait for next display tick
        guard state.dirty, !state.buffer.isEmpty else { return }
        flush()
    }

    private func scheduleFlush() {
        guard !state.flushScheduled else { return }
        state.flushScheduled = true
        // Safety net: ensure flush even if display ticks stall (e.g. app inactive)
        // This is rendering fallback, not PTY processing gate
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(32))
            self?.flushIfNeeded()
        }
    }

    private func flushIfNeeded() {
        guard state.dirty, !state.buffer.isEmpty else {
            state.flushScheduled = false
            return
        }
        // Only flush when dirty — tick is hint, not gate
        flush()
    }

    private func flush() {
        state.flushScheduled = false
        state.dirty = false
        guard !state.buffer.isEmpty else { return }
        let text = state.buffer
        let bytes = state.pendingBytes
        state.buffer = ""
        state.pendingBytes = 0
        pruneConsumers()
        for weakConsumer in state.consumers.values {
            weakConsumer.consumer?.receive(text)
            weakConsumer.consumer?.didConsume(bytes: bytes)
        }
    }

    private func pruneConsumers() {
        state.consumers = state.consumers.filter { $0.value.consumer != nil }
    }
}
