//
//  PTYSession.swift
//  Bonk
//

@preconcurrency import Citadel
import Darwin
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
    /// Raw output consumers used by process-backed command adapters.
    private let rawLiveContinuations = OSAllocatedUnfairLock<[UUID: AsyncStream<String>.Continuation]>(uncheckedState: [:])

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
    /// Serial port file descriptor. -1 when the session is not backed by a serial port.
    private let serialFDBox = NIOLockedValueBox<Int32>(-1)
    /// Whether the fd is owned by this session (serial) or by an external
    /// transport such as the OpenSSH subprocess (process mode).
    private let ownsFDBox = OSAllocatedUnfairLock<Bool>(uncheckedState: true)
    /// Process mode enables PTY resize over the same fd; serial mode ignores resize.
    private let processModeBox = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
    /// Optional raw process hook, called before UI output transformation.
    private let processOutputHandlerBox = NIOLockedValueBox<(@Sendable (Data) -> Void)?>(nil)
    /// Bytes typed while the SSH channel is still opening (first connect or
    /// reconnect). Flushed in order once the writer becomes available, so
    /// input right after a reconnect is never silently dropped.
    private let pendingInputBox = NIOLockedValueBox<[ByteBuffer]>([])
    private let onUnexpectedCloseBox = NIOLockedValueBox<(@Sendable () -> Void)?>(nil)
    /// Set by close() so the reader task knows the close was user-initiated
    /// and must NOT report an unexpected disconnect.
    private let userClosedBox = NIOLockedValueBox<Bool>(false)
    private static let maxPendingInputBytes = 64 * 1024

    /// Optional tap on bytes typed into the PTY (used to capture manual
    /// password entry during SSH auth). Observes only; never modifies input.
    private let inputTapBox = NIOLockedValueBox<(@Sendable (ArraySlice<UInt8>) -> Void)?>(nil)
    public var inputTap: (@Sendable (ArraySlice<UInt8>) -> Void)? {
        get { inputTapBox.withLockedValue { $0 } }
        set { inputTapBox.withLockedValue { $0 = newValue } }
    }

    /// OSC 7 CWD detector — intercepts escape sequences to track directory changes.
    let osc7Detector = PTYOSC7Detector()

    /// Zmodem handler for file transfer support.
    private(set) var zmodemHandler: ZmodemHandler?

    /// One-shot output observers for command-response patterns (e.g., getCWD).
    private typealias ObserverClosure = @Sendable (String) -> Void
    private let outputObservers = OSAllocatedUnfairLock<[UUID: ObserverClosure]>(uncheckedState: [:])

    /// Pending PTY size — caches resize requests when SSH channel is not yet ready.
    /// Prevents window-change packets from being silently dropped during connection setup.
    private let pendingSize = NIOLockedValueBox<(cols: Int, rows: Int)?>(nil)

    /// Called when a serial session ends unexpectedly (unplug / read error).
    public var onUnexpectedClose: (@Sendable () -> Void)? {
        get { onUnexpectedCloseBox.withLockedValue { $0 } }
        set { onUnexpectedCloseBox.withLockedValue { $0 = newValue } }
    }

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
            // Replay buffered output: strip OSC/DCS first (prevents
            // re-processing terminal query responses), then colorize for
            // display. The buffer itself stays raw.
            for line in buffer {
                let filtered = Self.filterOSCSequences(line)
                continuation.yield(LogColorizer.colorize(filtered))
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

    /// Create raw output stream for non-terminal consumers.
    ///
    /// No replay or UI colorization. Used by OpenSSH command/SFTP adapters.
    func makeRawOutputStream() -> AsyncStream<String> {
        let consumerID = UUID()
        return AsyncStream<String>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            self.rawLiveContinuations.withLock { $0[consumerID] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.rawLiveContinuations.withLock { _ = $0.removeValue(forKey: consumerID) }
            }
        }
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

        // Buffer RAW text only. Client-side log colorization is a DISPLAY
        // concern: it must never leak into the buffer, or AI context
        // (recentOutput), replay filtering, and copy paths all carry
        // injected SGR codes. The display feed below gets the colored text.
        let chunkBytes = text.utf8.count
        outputBuffer.withLockedValue { buf in
            buf.append(text)
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
        // Colorize for display only.
        let displayText = LogColorizer.colorize(text)
        // Send to all live consumers with per-consumer backpressure.
        // Skip consumers whose pending bytes exceed the high watermark;
        // they will resume once the Coordinator calls decrementPendingBytes().
        let consumers = liveContinuations.withLock { $0 }
        let displayChunkSize = displayText.utf8.count
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
            pendingBytes.withLock { $0[id, default: 0] += displayChunkSize }
            cont.yield(displayText)
        }

        let rawConsumers = rawLiveContinuations.withLock { $0 }
        for continuation in rawConsumers.values {
            continuation.yield(text)
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
                    self.flushPendingInput(to: outbound)

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

                    _ = Task {
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
        inputTapBox.withLockedValue { $0 }?(bytes)

        if let writer = writerBox.withLockedValue({ $0 }) {
            var buffer = ByteBuffer()
            buffer.writeBytes(bytes)
            try await writer.write(buffer)
            return
        }

        let fileDescriptor = serialFDBox.withLockedValue { $0 }
        guard fileDescriptor >= 0 else {
            // SSH channel not ready yet — queue instead of dropping.
            queuePendingInput(bytes)
            return
        }

        let data = Data(bytes)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return write(fileDescriptor, base.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try await Task.sleep(for: .milliseconds(5))
                    continue
                }
                throw SerialPortError.writeFailed(String(cString: strerror(errno)))
            }
            offset += written
        }
    }

    private func queuePendingInput(_ bytes: ArraySlice<UInt8>) {
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        pendingInputBox.withLockedValue { pending in
            let existingBytes = pending.reduce(0) { $0 + $1.readableBytes }
            guard existingBytes + buffer.readableBytes <= Self.maxPendingInputBytes else { return }
            pending.append(buffer)
        }
    }

    private func flushPendingInput(to writer: TTYStdinWriter) {
        let queued = pendingInputBox.withLockedValue { pending -> [ByteBuffer] in
            let buffers = pending
            pending.removeAll()
            return buffers
        }
        guard !queued.isEmpty else { return }
        Task {
            for buffer in queued {
                try? await writer.write(buffer)
            }
        }
    }

    /// Resize the PTY terminal dimensions.
    public func resize(cols: Int, rows: Int) async throws {
        let fileDescriptor = serialFDBox.withLockedValue { $0 }
        let isProcess = processModeBox.withLock { $0 }

        // Guard against garbage values (e.g., 131072x1 from un-laid-out views)
        let safeCols = max(1, min(cols, Self.maxCols))
        let safeRows = max(1, min(rows, Self.maxRows))
        guard safeCols > 1, safeRows > 1 else { return }

        if fileDescriptor >= 0, isProcess {
            var size = winsize()
            size.ws_col = UInt16(safeCols)
            size.ws_row = UInt16(safeRows)
            _ = Darwin.ioctl(fileDescriptor, UInt(TIOCSWINSZ), &size)
            return
        }

        guard fileDescriptor < 0 else { return }

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
        let fileDescriptor = serialFDBox.withLockedValue { $0 }
        let isProcess = processModeBox.withLock { $0 }
        let hasNativeWriter = writerBox.withLockedValue { $0 != nil }

        // Citadel PTYs have no file descriptor and write through TTYStdinWriter.
        // OpenSSH PTYs use the process-owned master fd. Both need cwd probing.
        if isProcess {
            guard fileDescriptor >= 0 else { return nil }
        } else {
            guard fileDescriptor < 0, hasNativeWriter else { return nil }
        }

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

                // Mark before writing so a fast PTY response cannot race past
                // the observer between write completion and this assignment.
                pwdSent.withLock { $0 = true }
                let input = Array("pwd\n".utf8)[...]
                try? await self.sendInput(input)
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

    /// Return the most recent buffered output lines (OSC/DCS stripped, ANSI intact).
    /// Used as LLM context for inline completion.
    public func recentOutput(maxLines: Int) -> String {
        let lines = outputBuffer.withLockedValue { $0 }
        return Array(lines.suffix(maxLines)).joined(separator: "")
    }

    /// Whether this session has been closed (user-initiated or via reader EOF).
    public var isClosed: Bool {
        if userClosedBox.withLockedValue({ $0 }) { return true }
        return serialFDBox.withLockedValue { $0 } < 0
    }

    /// Gracefully close the PTY session.
    public func close() {
        // Mark user-initiated FIRST so the reader task (cancelled below) does
        // not fire onUnexpectedClose when it notices the fd is gone. Only
        // genuinely unexpected disconnects should surface as errors.
        userClosedBox.withLockedValue { $0 = true }
        readerTaskBox.withLockedValue { $0?.cancel(); $0 = nil }
        writerBox.withLockedValue { $0 = nil }
        let fileDescriptor = serialFDBox.withLockedValue { current in
            let value = current
            current = -1
            return value
        }
        if fileDescriptor >= 0, ownsFDBox.withLock({ $0 }) {
            Darwin.close(fileDescriptor)
        }
        pendingInputBox.withLockedValue { $0.removeAll() }
        outputObservers.withLock { $0.removeAll() }
        liveContinuations.withLock { $0 }.values.forEach { $0.finish() }
        rawLiveContinuations.withLock { $0 }.values.forEach { $0.finish() }
        processOutputHandlerBox.withLockedValue { $0 = nil }
        sessionEndContinuation.finish()
    }

    // MARK: - Serial Port Mode

    /// Start reading from a serial port file descriptor.
    /// The session owns the descriptor and closes it on disconnect.
    func startSerial(fileDescriptor: Int32) {
        serialFDBox.withLockedValue { $0 = fileDescriptor }
        ownsFDBox.withLock { $0 = true }
        processModeBox.withLock { $0 = false }
        startReading(fileDescriptor: fileDescriptor)
    }

    /// Start reading from an OpenSSH subprocess PTY fd.
    /// The external transport owns the descriptor; this session only reads/writes it.
    func startProcess(
        fileDescriptor: Int32,
        onExit: @escaping @Sendable () -> Void,
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) {
        serialFDBox.withLockedValue { $0 = fileDescriptor }
        ownsFDBox.withLock { $0 = false }
        processModeBox.withLock { $0 = true }
        processOutputHandlerBox.withLockedValue { $0 = onOutput }
        onUnexpectedClose = onExit
        startReading(fileDescriptor: fileDescriptor)
    }

    private func startReading(fileDescriptor: Int32) {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)

            while !Task.isCancelled {
                // Wait for readable data in 100 ms slices so cancellation and
                // disconnect stay responsive while the port stays non-blocking.
                var pollDescriptor = pollfd(
                    fd: fileDescriptor,
                    events: Int16(POLLIN),
                    revents: 0
                )
                let pollResult = poll(&pollDescriptor, 1, 100)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if pollResult == 0 { continue }
                // POLLNVAL means the fd was closed underneath us (e.g. the
                // transport was closed while this reader was polling); treat
                // it as EOF instead of looping forever on an invalid fd.
                if pollDescriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    break
                }
                guard pollDescriptor.revents & Int16(POLLIN) != 0 else { continue }

                let bytesRead = read(fileDescriptor, &buffer, bufferSize)
                if bytesRead > 0 {
                    self?.yieldSerialOutput(Data(buffer[0 ..< bytesRead]))
                } else if bytesRead < 0 {
                    if errno != EINTR { break }
                } else {
                    break // EOF
                }
            }

            self?.finishSerial(fileDescriptor: fileDescriptor)
        }
        readerTaskBox.withLockedValue { $0 = task }
    }

    private func yieldSerialOutput(_ data: Data) {
        processOutputHandlerBox.withLockedValue { $0 }?(data)
        for chunk in Self.chunkData(data) {
            yieldOutput(String(bytes: chunk, encoding: .utf8) ?? "")
        }
    }

    private func finishSerial(fileDescriptor: Int32) {
        let ownedFD: Int32 = serialFDBox.withLockedValue { current in
            let value = current
            current = -1
            guard value == fileDescriptor else { return -1 }
            return ownsFDBox.withLock({ $0 }) ? value : -1
        }
        if ownedFD >= 0 { Darwin.close(ownedFD) }

        liveContinuations.withLock { $0 }.values.forEach { $0.finish() }
        rawLiveContinuations.withLock { $0 }.values.forEach { $0.finish() }
        let userClosed = userClosedBox.withLockedValue { $0 }
        if !userClosed {
            onUnexpectedCloseBox.withLockedValue { $0 }?()
        }
    }

    /// Split Data into UTF-8-safe chunks so escape sequences are not truncated.
    private static func chunkData(_ data: Data) -> [Data] {
        guard data.count > maxChunkBytes else { return [data] }

        var chunks: [Data] = []
        var offset = 0
        while offset < data.count {
            var end = min(offset + maxChunkBytes, data.count)
            if end < data.count {
                while end > offset, data[end] & 0xC0 == 0x80 {
                    end -= 1
                }
            }
            if end <= offset { end = min(offset + maxChunkBytes, data.count) }
            chunks.append(data.subdata(in: offset ..< end))
            offset = end
        }
        return chunks
    }

    // MARK: - Zmodem Support

    /// Initialize Zmodem handler for file transfer.
    func setupZmodem() {
        let handler = ZmodemHandler()
        handler.onSendData = { [weak self] data in
            Task {
                try? await self?.sendRawBytes(data)
            }
        }
        zmodemHandler = handler
    }

    /// Start Zmodem file send.
    public func startZmodemSend(files: [URL]) {
        let handler = zmodemHandler ?? {
            setupZmodem()
            return zmodemHandler!
        }()
        handler.startSend(files: files)
    }

    /// Start Zmodem file receive.
    public func startZmodemReceive() {
        let handler = zmodemHandler ?? {
            setupZmodem()
            return zmodemHandler!
        }()
        handler.startReceive()
    }

    /// Cancel Zmodem transfer.
    public func cancelZmodem() {
        zmodemHandler?.cancel()
    }

    /// Send raw bytes to the PTY.
    private func sendRawBytes(_ bytes: [UInt8]) async throws {
        guard let writer = writerBox.withLockedValue({ $0 }) else { return }
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        try await writer.write(buffer)
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
