//
//  PTYSession+SerialZmodem.swift
//  Bonk
//
//  Serial-port/process modes and Zmodem support extracted from PTYSession to keep
//  the class body within size limits. Same-module extension: internal members only.
//

@preconcurrency import Citadel
import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH
import os

// MARK: - PTYSession Serial Port Mode

extension PTYSession {
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
        let capturedGeneration = generation
        serialFDBox.withLockedValue { $0 = fileDescriptor }
        ownsFDBox.withLock { $0 = false }
        processModeBox.withLock { $0 = true }
        processOutputHandlerBox.withLockedValue { $0 = onOutput }
        onUnexpectedClose = onExit
        startReading(fileDescriptor: fileDescriptor, generation: capturedGeneration)
    }

    private func startReading(fileDescriptor: Int32) {
        startReading(fileDescriptor: fileDescriptor, generation: nil)
    }

    private func startReading(fileDescriptor: Int32, generation: UUID?) {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)

            while !Task.isCancelled {
                if let gen = generation, let currentGen = self?.generation, gen != currentGen {
                    Log.ssh.info("[PTY] Discard stale read task: gen=\(gen.uuidString.prefix(8)) != current=\(currentGen.uuidString.prefix(8))")
                    break
                }
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
                    break
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
            return ownsFDBox.withLock { $0 } ? value : -1
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
}

// MARK: - PTYSession Zmodem Support

public extension PTYSession {
    /// Initialize Zmodem handler for file transfer.
    internal func setupZmodem() {
        let handler = ZmodemHandler()
        handler.onSendData = { [weak self] data in
            Task {
                try? await self?.sendRawBytes(data)
            }
        }
        handler.onReceiveFileRequest = { info in
            // Accept gate for an untrusted inbound file. The name comes from
            // the remote host, so it is reduced to a single path component
            // before it can influence a destination; `../escape` and
            // `/etc/passwd` cannot select anything outside Downloads.
            // ZmodemHandler additionally re-checks containment and refuses to
            // write through symlinks.
            guard let safeName = ZmodemHandler.sanitizedRemoteName(info.name) else {
                Log.ssh.error("[Zmodem] rejected unsafe remote filename")
                return nil
            }
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            var dest = downloads.appendingPathComponent(safeName)
            // Avoid overwriting: add suffix if exists
            var counter = 1
            let ext = dest.pathExtension
            let base = dest.deletingPathExtension().lastPathComponent
            while FileManager.default.fileExists(atPath: dest.path) {
                let newName = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
                dest = downloads.appendingPathComponent(newName)
                counter += 1
            }
            return dest
        }
        handler.onProgress = { progress in
            Log.ssh.debug("[Zmodem] progress \(Int(progress * 100))%")
        }
        handler.onCompletion = { result in
            switch result {
            case let .success(url): Log.ssh.info("[Zmodem] completed \(url?.lastPathComponent ?? "done")")
            case let .failure(err): Log.ssh.error("[Zmodem] failed \(err.localizedDescription)")
            }
        }
        zmodemHandler = handler
    }

    /// Start Zmodem file send.
    func startZmodemSend(files: [URL]) {
        let handler = zmodemHandler ?? {
            setupZmodem()
            return zmodemHandler!
        }()
        handler.startSend(files: files)
    }

    /// Start Zmodem file receive.
    func startZmodemReceive() {
        let handler = zmodemHandler ?? {
            setupZmodem()
            return zmodemHandler!
        }()
        handler.startReceive()
    }

    /// Cancel Zmodem transfer.
    func cancelZmodem() {
        zmodemHandler?.cancel()
    }

    /// Send raw bytes to the PTY.
    private func sendRawBytes(_ bytes: [UInt8]) async throws {
        guard let writer = writerBox.withLockedValue({ $0 }) else { return }
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        try await writer.write(buffer)
    }
}
