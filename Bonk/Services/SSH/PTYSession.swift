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
    
    /// Track skipped chunks per consumer for diagnostics
    private let skippedChunks = OSAllocatedUnfairLock<[UUID: Int]>(uncheckedState: [:])

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

    /// Pending PTY size — caches resize requests when SSH channel is not yet ready.
    /// Prevents window-change packets from being silently dropped during connection setup.
    private let pendingSize = NIOLockedValueBox<(cols: Int, rows: Int)?>(nil)

    /// Callback invoked when the SSH channel writer becomes ready.
    /// Replaces the polling loop for faster PTY initialization.
    var onWriterReady: (@Sendable () -> Void)?

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
        
        Log.ssh.info("[PTY] Creating output stream for consumer \(consumerID.uuidString.prefix(8)), replaying \(buffer.count) buffered lines")

        let stream = AsyncStream<String>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            // Replay buffered output with OSC/DCS sequences stripped
            for line in buffer {
                continuation.yield(Self.filterOSCSequences(line))
            }

            // Register as live consumer
            self.liveContinuations.withLock { $0[consumerID] = continuation }
            self.pendingBytes.withLock { $0[consumerID] = 0 }

            continuation.onTermination = { [weak self] _ in
                self?.liveContinuations.withLock { _ = $0.removeValue(forKey: consumerID) }
                self?.pendingBytes.withLock { _ = $0.removeValue(forKey: consumerID) }
                Log.ssh.info("[PTY] Consumer \(consumerID.uuidString.prefix(8)) disconnected")
            }
        }

        let onBytesProcessed: @Sendable (Int) -> Void = { [weak self] count in
            self?.pendingBytes.withLock { dict in
                dict[consumerID, default: 0] = max(0, (dict[consumerID] ?? 0) - count)
            }
        }

        return (stream, onBytesProcessed)
    }

    /// Yield output to all consumers (buffer + live streams).
    private func yieldOutput(_ text: String) {
        // text is already chunked to safe size by chunkByteBuffer()

        // Process through OSC 7 detector for CWD tracking
        osc7Detector.process(text)

        // Notify one-shot observers (getCWD etc.) — raw text, no colorization
        let observers = outputObservers.withLock { $0 }
        for (_, observer) in observers {
            observer(text)
        }

        // Client-side log colorization: inject ANSI SGR codes for plain-text log lines.
        // Preserves existing ANSI sequences from the server — only colorizes plain text.
        let displayText = LogColorizer.colorize(text)

        // Add to buffer with byte-size limit
        let chunkBytes = displayText.utf8.count
        outputBuffer.withLockedValue { buf in
            buf.append(displayText)
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
        let chunkSize = displayText.utf8.count
        for (id, cont) in consumers {
            let pending = pendingBytes.withLock { dict in
                dict[id] ?? 0
            }
            if pending >= Self.backpressureHighWatermark {
                // Track skipped chunks for diagnostics
                skippedChunks.withLock { $0[id, default: 0] += 1 }
                let skipCount = skippedChunks.withLock { $0[id] ?? 0 }
                    // Log periodically (every 10 skips) to avoid spam
                    if skipCount % 10 == 1 {
                        Log.ssh.warning("[PTY] Consumer \(id.uuidString.prefix(8)) behind by \(pending) bytes, skipping chunk (skipped \(skipCount) chunks total)")
                    }
                continue // Consumer is too far behind, skip this chunk
            }
            pendingBytes.withLock { $0[id, default: 0] += chunkSize }
            cont.yield(displayText)
        }
    }

    /// Start the PTY session. Fire-and-forget — the session runs in a detached task.
    func start(client: SSHClient, cols: Int, rows: Int, termType: String) {
        let safeCols = max(cols, 1)
        let safeRows = max(rows, 1)
        Log.ssh.info("[PTY] Starting session with initial size: \(safeCols)x\(safeRows)")
        let endCont = sessionEndContinuation
        let endStream = sessionEndStream
        let writerBox = OSAllocatedUnfairLock<TTYStdinWriter?>(uncheckedState: nil)
        let onReady = self.onWriterReady

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

                    // Propagate writer to instance property (sendInput/resize read from here)
                    self.writerBox.withLockedValue { $0 = outbound }

                    // Writer is ready — notify via callback
                    onReady?()

                    // Flush any pending resize that was queued before channel was ready
                    if let size = self.pendingSize.withLockedValue({ $0 }) {
                        self.pendingSize.withLockedValue { $0 = nil }
                        do {
                            try await outbound.changeSize(cols: size.cols, rows: size.rows, pixelWidth: 0, pixelHeight: 0)
                            Log.ssh.info("[PTY] Flushed pending resize: \(size.cols)x\(size.rows)")
                        } catch {
                            Log.ssh.error("[PTY] Failed to flush pending resize: \(error)")
                        }
                    }

                    let readTask = Task {
                        do {
                            for try await data in inbound {
                                if Task.isCancelled { break }
                                switch data {
                                case let .stdout(buf):
                                    for chunk in Self.chunkByteBuffer(buf) {
                                        self.yieldOutput(chunk)
                                    }
                                case let .stderr(buf):
                                    for chunk in Self.chunkByteBuffer(buf) {
                                        self.yieldOutput(chunk)
                                    }
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

        guard let writer = writerBox.withLockedValue({ $0 }) else {
            // SSH channel not ready — queue resize for later, never discard
            pendingSize.withLockedValue { $0 = (safeCols, safeRows) }
            Log.ssh.debug("[PTY] SSH channel not ready, queued resize: \(safeCols)x\(safeRows)")
            return
        }

        try await writer.changeSize(cols: safeCols, rows: safeRows, pixelWidth: 0, pixelHeight: 0)
        Log.ssh.debug("[PTY] Resize sent: \(safeCols)x\(safeRows)")
    }

    /// Query the terminal's current working directory by sending `pwd` and parsing output.
    /// Returns nil if timeout or not at a shell prompt.
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
        let pwdSent = OSAllocatedUnfairLock<Bool>(uncheckedState: false)

        let observerID = UUID()
        let path: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let box = SendableContinuation(continuation)

            outputObservers.withLock { dict in
                dict[observerID] = { @Sendable (chunk: String) in
                    resumed.withLock { alreadyResumed in
                        guard !alreadyResumed else { return }

                        // Only process output after pwd command is sent
                        guard pwdSent.withLock({ $0 }) else { return }

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
                // Small delay before sending pwd to ensure previous output is processed
                try? await Task.sleep(for: .milliseconds(100))

                var buf = ByteBuffer()
                buf.writeString("pwd\n")
                try? await writer.write(buf)

                // Mark pwd as sent
                pwdSent.withLock { $0 = true }
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

    // MARK: - ByteBuffer Chunking

    /// Split a ByteBuffer into UTF-8-safe string chunks of at most maxChunkBytes.
    /// Respects UTF-8 code unit boundaries to avoid splitting multi-byte characters.
    private static func chunkByteBuffer(_ buffer: ByteBuffer) -> [String] {
        guard buffer.readableBytes > maxChunkBytes else {
            let str = String(buffer: buffer)
            return str.isEmpty ? [] : [str]
        }

        var results: [String] = []
        var offset = 0
        let totalBytes = buffer.readableBytes

        while offset < totalBytes {
            var end = min(offset + maxChunkBytes, totalBytes)

            // Find safe UTF-8 boundary: backtrack until we find a leading byte
            // (not a continuation byte 10xxxxxx)
            if end < totalBytes {
                while end > offset {
                    if let byte = buffer.getInteger(at: end, as: UInt8.self),
                       byte & 0xC0 != 0x80 { break }
                    end -= 1
                }
            }

            if let slice = buffer.getSlice(at: offset, length: end - offset) {
                let str = String(buffer: slice)
                if !str.isEmpty { results.append(str) }
            }
            offset = end
        }
        return results
    }

    // MARK: - OSC/DCS Sequence Filter

    private enum FilterState { case ground, escape, oscString, dcsEntry, dcsString, csi }

    /// Strip OSC and DCS escape sequences from a string.
    /// Preserves CSI sequences (cursor, SGR colors) which the terminal needs for rendering.
    /// Used during buffer replay to prevent re-processing terminal query responses.
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
                state = processEscapeByte(byte, result: &result)
            case .csi:
                state = processCSIByte(byte, result: &result)
            case .oscString:
                state = processOSCStringByte(byte)
            case .dcsEntry:
                state = processDCSEntryByte(byte)
            case .dcsString:
                state = processDCSStringByte(byte)
            }
        }

        return String(bytes: result, encoding: .utf8) ?? text
    }

    /// Process a byte in the escape state. Returns the next state.
    private nonisolated static func processEscapeByte(_ byte: UInt8, result: inout [UInt8]) -> FilterState {
        switch byte {
        case 0x5B: return .csi // [ → CSI (keep)
        case 0x5D: return .oscString // ] → OSC (strip)
        case 0x50: return .dcsEntry // P → DCS (strip)
        case 0x28, 0x29, 0x2A, 0x2B: // charset selectors
            result.append(0x1B); result.append(byte)
            return .ground
        default:
            result.append(0x1B); result.append(byte)
            return .ground
        }
    }

    /// Process a byte in the CSI state. Returns the next state.
    private nonisolated static func processCSIByte(_ byte: UInt8, result: inout [UInt8]) -> FilterState {
        result.append(byte)
        return (0x40 ... 0x7E).contains(byte) ? .ground : .csi
    }

    /// Process a byte in the OSC string state. Returns the next state.
    private nonisolated static func processOSCStringByte(_ byte: UInt8) -> FilterState {
        if byte == 0x07 { return .ground } // BEL terminator
        if byte == 0x1B { return .dcsString } // possible ESC \ (ST)
        return .oscString
    }

    /// Process a byte in the DCS entry state. Returns the next state.
    private nonisolated static func processDCSEntryByte(_ byte: UInt8) -> FilterState {
        byte == 0x1B ? .dcsString : .dcsEntry
    }

    /// Process a byte in the DCS string state. Returns the next state.
    private nonisolated static func processDCSStringByte(_ byte: UInt8) -> FilterState {
        if byte == 0x5C { return .ground } // \ → ST terminator
        if byte == 0x1B { return .dcsString } // another ESC
        return .dcsEntry
    }
}
