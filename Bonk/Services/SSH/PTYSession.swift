//
//  PTYSession.swift
//  Bonk
//

@preconcurrency import Citadel
import Foundation
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH
import os

/// Interactive PTY shell session.
///
/// Bridges Citadel's closure-based `withPTY` API into a long-lived object.
/// Uses a multicast output mechanism so multiple consumers (tab views) can
/// receive terminal output without losing history on tab switch.
public final nonisolated class PTYSession: @unchecked Sendable {
    /// Output buffer — stores recent lines for replay to new consumers.
    private let outputBuffer = NIOLockedValueBox<[String]>([])
    private let bufferByteCount = NIOLockedValueBox<Int>(0)
    private static let maxBufferSize = 10000
    private static let maxBufferBytes = 10 * 1024 * 1024 // 10 MB
    private static let maxChunkBytes = 64 * 1024 // 64 KB per chunk
    private static let maxCols = 500
    private static let maxRows = 200

    /// Live output continuations — yields new data to all active feed tasks.
    private let liveContinuations = OSAllocatedUnfairLock<[UUID: AsyncStream<String>.Continuation]>(uncheckedState: [:])

    /// Per-consumer pending byte tracking for backpressure control.
    /// Prevents slow consumers from accumulating unbounded buffered data.
    private let pendingBytes = OSAllocatedUnfairLock<[UUID: Int]>(uncheckedState: [:])
    private static let backpressureHighWatermark = 256 * 1024 // 256 KB — pause yielding
    private static let backpressureLowWatermark = 64 * 1024 // 64 KB — resume yielding

    /// Internal signal — finishes when the session should end.
    private let sessionEndStream: AsyncStream<Void>
    private let sessionEndContinuation: AsyncStream<Void>.Continuation

    private let writerBox = NIOLockedValueBox<TTYStdinWriter?>(nil)
    private let readerTaskBox = NIOLockedValueBox<Task<Void, Never>?>(nil)

    /// OSC 7 CWD detector — intercepts escape sequences to track directory changes.
    let osc7Detector = PTYOSC7Detector()

    /// One-shot output observers for command-response patterns (e.g., getCWD).
    private typealias ObserverClosure = @Sendable (String) -> Void
    private let outputObservers = OSAllocatedUnfairLock<[UUID: ObserverClosure]>(uncheckedState: [:])

    init() {
        var endCont: AsyncStream<Void>.Continuation!
        (sessionEndStream, endCont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        sessionEndContinuation = endCont
    }

    /// Create an output stream for a consumer.
    /// Replays buffered output first, then streams live data.
    /// OSC/DCS sequences are stripped from replay to prevent re-processing
    /// terminal query responses (color queries, DECRPM) that cause garbled output.
    /// Create an output stream for a consumer.
    ///
    /// Returns a tuple of (stream, onBytesProcessed). The caller must call
    /// `onBytesProcessed(byteCount)` after consuming each chunk so the backpressure
    /// tracking stays accurate. When pending bytes exceed the high watermark,
    /// the producer skips this consumer until it catches up.
    public func makeOutputStream() -> (stream: AsyncStream<String>, onBytesProcessed: @Sendable (Int) -> Void) {
        let buffer = outputBuffer.withLockedValue { $0 }
        let consumerID = UUID()

        let stream = AsyncStream<String>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            // Replay buffered output with OSC/DCS sequences stripped
            for line in buffer {
                continuation.yield(Self.filterOSCSequences(line))
            }

            // Register as live consumer
            self.liveContinuations.withLock { $0[consumerID] = continuation }
            self.pendingBytes.withLock { $0[consumerID] = 0 }

            continuation.onTermination = { [self] _ in
                liveContinuations.withLock { _ = $0.removeValue(forKey: consumerID) }
                pendingBytes.withLock { _ = $0.removeValue(forKey: consumerID) }
            }
        }

        let onBytesProcessed: @Sendable (Int) -> Void = { [self] count in
            pendingBytes.withLock { dict in
                dict[consumerID, default: 0] = max(0, (dict[consumerID] ?? 0) - count)
            }
        }

        return (stream, onBytesProcessed)
    }

    /// Yield output to all consumers (buffer + live streams).
    private func yieldOutput(_ text: String) {
        // Truncate oversized chunks to prevent memory spikes
        let chunk: String
        let maxBytes = Self.maxChunkBytes
        if text.utf8.count > maxBytes {
            let end = text.index(text.startIndex, offsetBy: maxBytes, limitedBy: text.endIndex) ?? text.endIndex
            chunk = String(text[..<end])
        } else {
            chunk = text
        }

        // Process through OSC 7 detector for CWD tracking
        osc7Detector.process(chunk)

        // Notify one-shot observers (getCWD etc.)
        let observers = outputObservers.withLock { $0 }
        for (_, observer) in observers {
            observer(chunk)
        }

        // Add to buffer with byte-size limit
        let chunkBytes = chunk.utf8.count
        outputBuffer.withLockedValue { buf in
            buf.append(chunk)
            bufferByteCount.withLockedValue { $0 += chunkBytes }
            // Trim by line count
            if buf.count > Self.maxBufferSize {
                let removed = buf.count - Self.maxBufferSize
                buf.removeFirst(removed)
            }
            // Trim by byte count
            while bufferByteCount.withLockedValue({ $0 }) > Self.maxBufferBytes, buf.count > 1 {
                if let first = buf.first {
                    bufferByteCount.withLockedValue { $0 -= first.utf8.count }
                    buf.removeFirst()
                }
            }
        }
        // Send to all live consumers with per-consumer backpressure.
        // Skip consumers whose pending bytes exceed the high watermark;
        // they will resume once the Coordinator calls decrementPendingBytes().
        let consumers = liveContinuations.withLock { $0 }
        let chunkSize = chunk.utf8.count
        for (id, cont) in consumers {
            let pending = pendingBytes.withLock { dict in
                dict[id] ?? 0
            }
            if pending >= Self.backpressureHighWatermark {
                continue // Consumer is too far behind, skip this chunk
            }
            pendingBytes.withLock { $0[id, default: 0] += chunkSize }
            cont.yield(chunk)
        }
    }

    // Start the PTY session. Fire-and-forget — the session runs in a detached task.
    func start(client: SSHClient, cols: Int, rows: Int, termType: String) {
        let safeCols = max(cols, 1)
        let safeRows = max(rows, 1)
        let endCont = sessionEndContinuation
        let endStream = sessionEndStream
        let writerBox = OSAllocatedUnfairLock<TTYStdinWriter?>(uncheckedState: nil)

        let ptyTask = Task.detached {
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: termType,
                terminalCharacterWidth: safeCols,
                terminalRowHeight: safeRows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )

            do {
                try await client.withPTY(request) { inbound, outbound in
                    writerBox.withLock { $0 = outbound }

                    let readTask = Task {
                        do {
                            for try await data in inbound {
                                if Task.isCancelled { break }
                                switch data {
                                case let .stdout(buf):
                                    let output = String(buffer: buf)
                                    if !output.isEmpty { self.yieldOutput(output) }
                                case let .stderr(buf):
                                    let errorOutput = String(buffer: buf)
                                    if !errorOutput.isEmpty { self.yieldOutput(errorOutput) }
                                }
                            }
                        } catch {
                            Log.ssh.debug("PTY read channel closed: \(error.localizedDescription)")
                        }
                        self.liveContinuations.withLock { $0 }.values.forEach { $0.finish() }
                        endCont.finish()
                    }

                    for await _ in endStream {}
                    _ = readTask
                }
            } catch {
                self.liveContinuations.withLock { $0 }.values.forEach { $0.finish() }
                endCont.finish()
            }
        }

        Task {
            var delay: UInt64 = 10
            var writer: TTYStdinWriter?
            while true {
                writer = writerBox.withLock { $0 }
                if writer != nil || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(Double(delay)))
                delay = min(delay * 2, 100)
            }
            self.writerBox.withLockedValue { $0 = writer }
        }

        readerTaskBox.withLockedValue { $0 = ptyTask }
    }

    /// Write keyboard input to the remote shell's stdin.
    public func sendInput(_ bytes: ArraySlice<UInt8>) async throws {
        guard let writer = writerBox.withLockedValue({ $0 }) else { return }
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        try await writer.write(buffer)
    }

    /// Resize the PTY terminal dimensions.
    public func resize(cols: Int, rows: Int) async throws {
        // Guard against garbage values (e.g., 131072x1 from un-laid-out views)
        let safeCols = max(1, min(cols, Self.maxCols))
        let safeRows = max(1, min(rows, Self.maxRows))
        guard safeCols > 1, safeRows > 1 else { return }
        guard let writer = writerBox.withLockedValue({ $0 }) else { return }
        try await writer.changeSize(cols: safeCols, rows: safeRows, pixelWidth: 0, pixelHeight: 0)
    }

    // Query the terminal's current working directory by sending `pwd` and parsing output.
    // Returns nil if timeout or not at a shell prompt.
    public func getCWD() async -> String? {
        guard let writer = writerBox.withLockedValue({ $0 }) else { return nil }

        // Wrappers to satisfy @Sendable requirements across isolation boundaries.
        final class SendableContinuation: @unchecked Sendable {
            let value: CheckedContinuation<String?, Never>
            init(_ continuation: CheckedContinuation<String?, Never>) {
                value = continuation
            }
        }

        let resumed = OSAllocatedUnfairLock<Bool>(uncheckedState: false)

        let observerID = UUID()
        let path: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let box = SendableContinuation(continuation)

            outputObservers.withLock { dict in
                dict[observerID] = { @Sendable (chunk: String) in
                    resumed.withLock { alreadyResumed in
                        guard !alreadyResumed else { return }
                        let lines = chunk.components(separatedBy: "\r\n")
                        for raw in lines {
                            let clean = raw
                                .replacingOccurrences(
                                    of: "\u{1B}\\[[0-9;]*[a-zA-Z]",
                                    with: "", options: .regularExpression
                                )
                                .replacingOccurrences(
                                    of: "\u{1B}\\][^\u{07}\u{1B}]*[\u{07}]",
                                    with: "", options: .regularExpression
                                )
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if clean.hasPrefix("/"), !clean.contains(" "), clean.count < 512 {
                                alreadyResumed = true
                                box.value.resume(returning: clean)
                                return
                            }
                        }
                    }
                }
            }

            Task {
                var buf = ByteBuffer()
                buf.writeString("pwd\n")
                try? await writer.write(buf)
            }

            Task {
                try? await Task.sleep(for: .seconds(2))
                resumed.withLock { alreadyResumed in
                    guard !alreadyResumed else { return }
                    alreadyResumed = true
                    box.value.resume(returning: nil)
                }
            }
        }

        outputObservers.withLock { _ = $0.removeValue(forKey: observerID) }
        return path
    }

    /// Gracefully close the PTY session.
    public func close() {
        readerTaskBox.withLockedValue { $0?.cancel(); $0 = nil }
        writerBox.withLockedValue { $0 = nil }
        _ = outputObservers.withLock { $0.removeAll() }
        liveContinuations.withLock { $0 }.values.forEach { $0.finish() }
        sessionEndContinuation.finish()
    }

    // MARK: - OSC/DCS Sequence Filter

    private enum FilterState { case ground, escape, oscString, dcsEntry, dcsString, csi }

    // Strip OSC and DCS escape sequences from a string.
    // Preserves CSI sequences (cursor, SGR colors) which the terminal needs for rendering.
    // Used during buffer replay to prevent re-processing terminal query responses.
    nonisolated static func filterOSCSequences(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var result = [UInt8]()
        result.reserveCapacity(bytes.count)
        var state: FilterState = .ground

        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape } else { result.append(byte) }

            case .escape:
                switch byte {
                case 0x5B: state = .csi // [ → CSI (keep)
                case 0x5D: state = .oscString // ] → OSC (strip)
                case 0x50: state = .dcsEntry // P → DCS (strip)
                case 0x28, 0x29, 0x2A, 0x2B: // charset selectors
                    result.append(0x1B); result.append(byte)
                    state = .ground
                default:
                    result.append(0x1B); result.append(byte)
                    state = .ground
                }

            case .csi:
                result.append(byte)
                if (0x40 ... 0x7E).contains(byte) { state = .ground }

            case .oscString:
                if byte == 0x07 { state = .ground } // BEL terminator
                else if byte == 0x1B { state = .dcsString } // possible ESC \ (ST)

            case .dcsEntry:
                if byte == 0x1B { state = .dcsString }

            case .dcsString:
                if byte == 0x5C { state = .ground } // \ → ST terminator
                else if byte == 0x1B { /* stay */ } // another ESC
                else { state = .dcsEntry }
            }
        }

        return String(bytes: result, encoding: .utf8) ?? text
    }
}
