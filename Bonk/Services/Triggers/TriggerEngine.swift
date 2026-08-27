//
//  TriggerEngine.swift
//  Bonk
//
//  Pane-aware subscription engine for triggers (Phase 7).
//  Replaces per-chunk Task@MainActor in PTY yieldOutput.
//  Batches output per paneID and debounces to at most one
//  MainActor hop per 32ms, threading paneID for per-pane throttle.
//

import Foundation
import os

/// Pane-aware trigger batching. PTY hot path calls `enqueue` (lock only, no MainActor hop).
/// Flush batches once per interval and delegates to `TriggerManager` (still owns rule cache + dispatch).
final class TriggerEngine: @unchecked Sendable {
    static let shared = TriggerEngine()

    // Global sentinel for output where paneID is not yet bound.
    static let globalPaneID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private struct State {
        var buffers: [UUID: String] = [:]
        var sessions: [UUID: PTYSession?] = [:]
        var scheduled: [UUID: UInt64] = [:]
        var nextGen: UInt64 = 0
        var bufferBytes: [UUID: Int] = [:]
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())
    private static let flushInterval = Duration.milliseconds(32)
    private static let maxBatchBytes = 64 * 1024
    private static let maxBufferBytes = 256 * 1024

    private init() {}

    // MARK: - Public API

    /// Called from PTYSession.yieldOutput — lock only, never hops to MainActor.
    func enqueue(paneID: UUID?, text: String, ptySession: PTYSession?) {
        guard !text.isEmpty else { return }
        let key = paneID ?? Self.globalPaneID
        let shouldFlushImmediately: Bool
        let generation: UInt64?
        (shouldFlushImmediately, generation) = state.withLock { s in
            s.buffers[key, default: ""].append(text)
            s.bufferBytes[key, default: 0] += text.utf8.count
            // Keep most recent session for sendText actions
            s.sessions[key] = ptySession
            // Bound buffer to prevent unbounded growth under `yes | head`
            if s.bufferBytes[key, default: 0] > Self.maxBufferBytes {
                // Drop oldest half — triggers are line oriented, losing early bytes is acceptable
                let buf = s.buffers[key] ?? ""
                let dropCount = buf.count / 2
                if dropCount > 0 {
                    let idx = buf.index(buf.startIndex, offsetBy: dropCount)
                    s.buffers[key] = String(buf[idx...])
                    s.bufferBytes[key] = s.buffers[key]?.utf8.count ?? 0
                }
            }
            if s.bufferBytes[key, default: 0] >= Self.maxBatchBytes {
                s.scheduled[key] = nil
                return (true, nil)
            }
            if s.scheduled[key] != nil {
                return (false, nil)
            }
            s.nextGen &+= 1
            let gen = s.nextGen
            s.scheduled[key] = gen
            return (false, gen)
        }

        if shouldFlushImmediately {
            flush(key: key, generation: nil, paneID: paneID)
        } else if let gen = generation {
            scheduleFlush(key: key, generation: gen, paneID: paneID)
        }
    }

    /// Explicit subscription — pre-creates buffer to avoid first-chunk allocation.
    func subscribe(paneID: UUID) {
        state.withLock { s in
            if s.buffers[paneID] == nil {
                s.buffers[paneID] = ""
                s.bufferBytes[paneID] = 0
            }
        }
    }

    func unsubscribe(paneID: UUID) {
        state.withLock { s in
            s.buffers.removeValue(forKey: paneID)
            s.sessions.removeValue(forKey: paneID)
            s.scheduled.removeValue(forKey: paneID)
            s.bufferBytes.removeValue(forKey: paneID)
        }
    }

    // Legacy signature kept for compatibility (no-op wrapper)
    func subscribe(paneID: UUID, rule: TriggerRule) { subscribe(paneID: paneID) }

    // MARK: - Scheduling

    private func scheduleFlush(key: UUID, generation: UInt64, paneID: UUID?) {
        Task.detached { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard !Task.isCancelled else { return }
            self?.flush(key: key, generation: generation, paneID: paneID)
        }
    }

    private func flush(key: UUID, generation: UInt64?, paneID: UUID?) {
        let payload: (text: String, session: PTYSession?)?
        payload = state.withLock { s in
            if let gen = generation, s.scheduled[key] != gen {
                return nil
            }
            s.scheduled[key] = nil
            guard let buf = s.buffers[key], !buf.isEmpty else { return nil }
            let session = s.sessions[key] ?? nil
            s.buffers[key] = ""
            s.bufferBytes[key] = 0
            return (buf, session)
        }
        guard let payload, !payload.text.isEmpty else { return }
        // Single MainActor hop per batch (was per-chunk Task@MainActor)
        let originalPaneID: UUID? = (key == Self.globalPaneID) ? nil : paneID ?? key
        Task { @MainActor in
            TriggerManager.shared.processOutput(payload.text, paneID: originalPaneID, ptySession: payload.session)
        }
    }

    // MARK: - Testing

    /// Flush immediately for tests — bypass timer.
    func flushForTest(paneID: UUID?) {
        let key = paneID ?? Self.globalPaneID
        flush(key: key, generation: nil, paneID: paneID)
    }

    func bufferedBytesForTest(paneID: UUID?) -> Int {
        let key = paneID ?? Self.globalPaneID
        return state.withLock { $0.bufferBytes[key] ?? 0 }
    }
}
