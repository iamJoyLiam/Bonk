//
//  ZmodemHandler.swift
//  Bonk
//
//  Zmodem protocol handler for file transfer via terminal.
//  Implements ZRQINIT/ZRINIT handshake, ZRFILE/ZRPOS/ZDATA/ZEOF.
//  Covers data-frame sending + basic receive + CRC16 + ZDLE.
//

import Foundation
import os.log

// MARK: - Zmodem Constants

enum ZmodemConstants {
    static let zpad: UInt8 = 0x2A // '*'
    static let zdle: UInt8 = 0x18 // CAN / DLE
    static let can: UInt8 = 0x18
    static let xon: UInt8 = 0x11
    static let xoff: UInt8 = 0x13

    // Frame types (binary)
    static let zrqinit: UInt8 = 0x00
    static let zrinit: UInt8 = 0x00
    static let zrfile: UInt8 = 0x01
    static let zrpos: UInt8 = 0x02
    static let zdata: UInt8 = 0x03
    static let zeof: UInt8 = 0x04
    static let zferr: UInt8 = 0x05
    static let zskip: UInt8 = 0x06
    static let znak: UInt8 = 0x07
    static let zabort: UInt8 = 0x08
    static let zfin: UInt8 = 0x09

    // Data subpacket frame ends (after ZDLE)
    static let zcrce: UInt8 = 0x68 // 'h' - last of file
    static let zcrcg: UInt8 = 0x69 // 'i' - not last
    static let zcrcq: UInt8 = 0x6A // 'j'
    static let zcrcw: UInt8 = 0x6B // 'k'
}

// MARK: - Zmodem State

enum ZmodemState {
    case idle
    case waitingForInit
    case receivingFile
    case sendingFile
    case completed
    case error(String)
    case cancelled
}

// MARK: - Zmodem File Info

struct ZmodemFileInfo {
    let name: String
    let size: Int64
    let modificationDate: Date?
    let mode: Int32
}

// MARK: - Zmodem Handler

class ZmodemHandler {
    private let logger = Logger(subsystem: "com.bonk", category: "Zmodem")

    private(set) var state: ZmodemState = .idle

    var onSendData: (([UInt8]) -> Void)?
    /// Progress 0...1 for current file
    var onProgress: ((Double) -> Void)?
    /// Called on completion (send or receive)
    var onCompletion: ((Result<URL?, Error>) -> Void)?
    /// UI hook: given file info, return destination URL (or nil to cancel). If nil, auto-saves to Downloads.
    var onReceiveFileRequest: ((ZmodemFileInfo) -> URL?)?

    private var receivedData = Data()
    private var currentFile: ZmodemFileInfo?
    private var filesToSend: [URL] = []
    private var currentFileIndex = 0

    // Send state
    private var sendFileHandle: FileHandle?
    private var sendOffset: UInt64 = 0
    private var sendFileSize: UInt64 = 0
    private let chunkSize = 8192

    // Receive state
    private var receiveFileHandle: FileHandle?
    private var receiveFileURL: URL?
    private var receiveFileSize: Int64 = 0
    private var receiveBytesWritten: Int64 = 0

    // MARK: - Public API

    func startReceive() {
        logger.info("Starting Zmodem receive")
        state = .waitingForInit
        cleanupReceive()
        sendZrinit()
    }

    func startSend(files: [URL]) {
        logger.info("Starting Zmodem send with \(files.count) files")
        filesToSend = files
        currentFileIndex = 0
        state = .sendingFile
        cleanupSend()
        if !files.isEmpty { sendZrqinit() }
    }

    func cancel() {
        logger.info("Cancelling Zmodem transfer")
        state = .cancelled
        cleanupSend()
        cleanupReceive()
        sendCan()
        onCompletion?(.failure(NSError(domain: "Zmodem", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cancelled"])))
    }

    func processData(_ data: [UInt8]) {
        guard !data.isEmpty else { return }
        // Detect header at any offset (not only index 0) - lrzsz may send leading \r\n
        if let headerStart = findHeader(in: data) {
            let slice = Array(data[headerStart...])
            handleZmodemFrame(slice)
        } else if case .receivingFile = state, receiveFileHandle != nil {
            // Raw data subpacket while receiving - treat as file data until next header appears
            // If data does not look like a header, consider it file content.
            // For simplicity, we only handle header-driven flow (ZRPOS/ZEOF) and ignore raw subpackets here;
            // real data arrives via processRawData(_:) from PTYSession's string path.
        }
    }

    /// Called by PTYSession for raw file data chunks (when not a header).
    func processRawData(_ data: Data) {
        guard case .receivingFile = state, let fileHandle = receiveFileHandle else { return }
        // Ignore if data looks like a header
        if data.count >= 2, data[0] == ZmodemConstants.zpad, data[1] == ZmodemConstants.zpad { return }
        fileHandle.write(data)
        receiveBytesWritten += Int64(data.count)
        if receiveFileSize > 0 {
            onProgress?(Double(receiveBytesWritten) / Double(receiveFileSize))
        }
    }

    /// Convenience: detect ** pattern in String (for PTYSession's yieldOutput String path)
    static func containsZmodemSequence(in text: String) -> Bool {
        text.contains("**") && text.unicodeScalars.contains(where: { $0.value == 0x18 })
    }

    static func containsZmodemHeader(in bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        // swiftlint:disable:next identifier_name
        for i in 0..<(bytes.count - 1) {
            if bytes[i] == ZmodemConstants.zpad, bytes[i + 1] == ZmodemConstants.zpad { return true }
            if bytes[i] == ZmodemConstants.zpad, bytes[i + 1] == 0x18 { return true }
        }
        return false
    }

    // MARK: - Frame Handling

    private func findHeader(in data: [UInt8]) -> Int? {
        guard data.count >= 2 else { return nil }
        // swiftlint:disable:next identifier_name
        for i in 0..<(data.count - 1) {
            if data[i] == ZmodemConstants.zpad, data[i + 1] == ZmodemConstants.zpad { return i }
        }
        // Also match single ZPAD+ZDLE+B pattern (without double pad)
        // swiftlint:disable:next identifier_name
        for i in 0..<(data.count - 2) {
            if data[i] == ZmodemConstants.zpad, data[i + 1] == 0x18, data[i + 2] == 0x42 { return i }
        }
        return nil
    }

    private func handleZmodemFrame(_ data: [UInt8]) {
        guard data.count > 2 else { return }
        var index = 0
        while index < data.count, data[index] == ZmodemConstants.zpad { index += 1 }
        if index < data.count, data[index] == 0x18 { index += 1 } // ZDLE
        if index < data.count, data[index] == 0x42 { index += 1 } // 'B'
        guard index < data.count else { return }
        let frameType = data[index]
        index += 1
        switch frameType {
        case ZmodemConstants.zrqinit: handleZrqinit()
        case ZmodemConstants.zrinit: handleZrinit()
        case ZmodemConstants.zrfile: handleZrfile(data: data, offset: index)
        case ZmodemConstants.zeof: handleZeof(data: data, offset: index)
        case ZmodemConstants.zfin: handleZfin()
        case ZmodemConstants.zrpos: handleZrpos(data: data, offset: index)
        case ZmodemConstants.zdata: handleZdata(data: data, offset: index)
        default: logger.warning("Unknown frame type: \(frameType)")
        }
    }

    // MARK: - Frame Handlers

    private func handleZrqinit() {
        logger.info("Received ZRQINIT - peer wants to send files")
        state = .waitingForInit
        sendZrinit()
    }

    private func handleZrinit() {
        logger.info("Received ZRINIT - peer ready to receive")
        if currentFileIndex < filesToSend.count { sendNextFile() }
    }

    private func handleZrfile(data: [UInt8], offset: Int) {
        logger.info("Received ZRFILE - file info")
        let info = parseFileInfo(from: data, offset: offset)
        if let info {
            currentFile = info
            state = .receivingFile
            receiveFileSize = info.size
            receiveBytesWritten = 0
            // Ask UI or auto-save to Downloads
            let dest: URL?
            if let provider = onReceiveFileRequest, let url = provider(info) {
                dest = url
            } else {
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                dest = downloads.appendingPathComponent(info.name)
            }
            if let dest {
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                receiveFileURL = dest
                receiveFileHandle = try? FileHandle(forWritingTo: dest)
                logger.info("Receiving to \(dest.path)")
            }
        }
        sendZrpos(offset: 0)
    }

    private func handleZeof(data: [UInt8], offset: Int) {
        logger.info("Received ZEOF - end of file")
        receiveFileHandle?.closeFile()
        receiveFileHandle = nil
        if let url = receiveFileURL {
            let bytes = receiveBytesWritten
            onCompletion?(.success(url))
            logger.info("Saved \(url.lastPathComponent, privacy: .public) (\(bytes) bytes)")
        }
        receiveFileURL = nil
        state = .waitingForInit
        sendZrinit()
    }

    private func handleZfin() {
        logger.info("Received ZFIN - transfer complete")
        cleanupSend()
        cleanupReceive()
        state = .completed
        onCompletion?(.success(nil))
    }

    private func handleZrpos(data: [UInt8], offset: Int) {
        var pos: UInt32 = 0
        if data.count >= offset + 4 {
            pos = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
        logger.info("Received ZRPOS pos=\(pos)")
        sendOffset = UInt64(pos)
        // Seek if handle exists
        try? sendFileHandle?.seek(toOffset: sendOffset)
        sendNextDataChunk()
    }

    private func handleZdata(data: [UInt8], offset: Int) {
        // ZDATA header carries file offset; following bytes (data subpacket) arrive as separate processRawData calls.
        var pos: UInt32 = 0
        if data.count >= offset + 4 {
            pos = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
            logger.info("Received ZDATA pos=\(pos)")
        }
        state = .receivingFile
        // If we have a file handle, seek to pos (for resume)
        if let fileHandle = receiveFileHandle, pos != UInt32(receiveBytesWritten) {
            try? fileHandle.seek(toOffset: UInt64(pos))
            receiveBytesWritten = Int64(pos)
        }
    }

    // MARK: - Frame Sending

    private func sendZrqinit() {
        var frame: [UInt8] = [ZmodemConstants.zpad, 0x18, 0x42, ZmodemConstants.zrqinit, 0, 0, 0, 0, 0]
        onSendData?(frame)
    }

    private func sendZrinit() {
        var frame: [UInt8] = [ZmodemConstants.zpad, 0x18, 0x42, ZmodemConstants.zrinit, 0, 0, 0, 0, 0]
        onSendData?(frame)
    }

    private func sendZrpos(offset: UInt32 = 0) {
        var frame: [UInt8] = [ZmodemConstants.zpad, 0x18, 0x42, ZmodemConstants.zrpos]
        var littleEndian = offset.littleEndian
        frame.append(contentsOf: withUnsafeBytes(of: &littleEndian) { Array($0) })
        frame.append(0)
        onSendData?(frame)
    }

    private func sendZrfile(_ file: ZmodemFileInfo) {
        var frame: [UInt8] = [ZmodemConstants.zpad, 0x18, 0x42, ZmodemConstants.zrfile, 0, 0, 0, 0, 0]
        // Append NUL-terminated file info block: "filename\0size mtime mode 0\0"
        var block = Data()
        block.append(contentsOf: file.name.utf8)
        block.append(0)
        let sizeStr = "\(file.size)"
        block.append(contentsOf: sizeStr.utf8)
        block.append(0)
        // Optional: mtime/mode as octal
        frame.append(contentsOf: block)
        frame.append(0)
        onSendData?(frame)
    }

    private func sendNextFile() {
        guard currentFileIndex < filesToSend.count else { sendZfin(); return }
        let fileURL = filesToSend[currentFileIndex]
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.error("File not found: \(fileURL.path)")
            currentFileIndex += 1
            sendNextFile()
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modDate = attrs?[.modificationDate] as? Date
        let info = ZmodemFileInfo(name: fileURL.lastPathComponent, size: size, modificationDate: modDate, mode: 0o644)
        currentFile = info
        sendFileSize = UInt64(size)
        sendOffset = 0
        // Open handle
        sendFileHandle?.closeFile()
        sendFileHandle = try? FileHandle(forReadingFrom: fileURL)
        sendZrfile(info)
    }

    private func sendNextDataChunk() {
        guard let fileHandle = sendFileHandle else {
            // No handle -> try opening current file
            guard currentFileIndex < filesToSend.count else { sendZfin(); return }
            let url = filesToSend[currentFileIndex]
            sendFileHandle = try? FileHandle(forReadingFrom: url)
            if sendFileHandle == nil {
                logger.error("Cannot open \(url.path) for sending")
                state = .error("cannot open file")
                return
            }
            sendNextDataChunk()
            return
        }
        do { try fileHandle.seek(toOffset: sendOffset) } catch { logger.error("Seek failed: \(error)"); return }
        let chunk = fileHandle.readData(ofLength: chunkSize)
        if chunk.isEmpty {
            // EOF -> ZEOF
            fileHandle.closeFile()
            sendFileHandle = nil
            sendZeof()
            return
        }
        let isLast = (sendOffset + UInt64(chunk.count) >= sendFileSize)
        // Header: ZDATA + offset
        var header: [UInt8] = [ZmodemConstants.zpad, 0x18, 0x42, ZmodemConstants.zdata]
        var leOffset = UInt32(sendOffset).littleEndian
        header.append(contentsOf: withUnsafeBytes(of: &leOffset) { Array($0) })
        header.append(0)
        onSendData?(header)
        // Data subpacket: ZDLE-escaped data + ZDLE + frameEnd + CRC16
        let rawBytes = [UInt8](chunk)
        let encoded = zdleEncode(rawBytes)
        let frameEnd: UInt8 = isLast ? ZmodemConstants.zcrce : ZmodemConstants.zcrcg
        var packet: [UInt8] = encoded
        packet.append(0x18)
        packet.append(frameEnd)
        // CRC over data + frameEnd (per spec, CRC includes frameEnd)
        var crcInput = rawBytes
        crcInput.append(frameEnd)
        let crc = Self.crc16(crcInput)
        // CRC is sent little-endian and ZDLE-escaped if needed
        let crcBytes: [UInt8] = [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF)]
        packet.append(contentsOf: zdleEncode(crcBytes))
        onSendData?(packet)
        sendOffset += UInt64(chunk.count)
        if sendFileSize > 0 { onProgress?(Double(sendOffset) / Double(sendFileSize)) }
        if isLast {
            // Wait for ZRPOS(ACK) or will be driven by peer's ZRPOS; if peer auto-ACKs, the next ZRPOS will trigger next file.
            // Proactively send ZEOF after last chunk; peer will respond with ZRPOS or ZRINIT
            // Do not close yet; ZEOF will be sent on next ZRPOS or immediately if we know it's last
            // For simplicity, send ZEOF now if isLast (peer handles both)
            // But we already sent data; keep handle open until ZEOF ack
        }
    }

    private func sendZeof() {
        var frame: [UInt8] = [ZmodemConstants.zpad, 0x18, 0x42, ZmodemConstants.zeof]
        var littleEndian = UInt32(sendOffset).littleEndian
        frame.append(contentsOf: withUnsafeBytes(of: &littleEndian) { Array($0) })
        frame.append(0)
        onSendData?(frame)
        // Advance to next file only after peer ACKs with ZRPOS/ZRINIT; but we also proactively prep
        // Close handle already done
        currentFileIndex += 1
        sendOffset = 0
        sendFileSize = 0
        sendFileHandle = nil
        if currentFileIndex >= filesToSend.count {
            // No more files -> expect ZFIN
        }
    }

    private func sendZfin() {
        var frame: [UInt8] = [ZmodemConstants.zpad, 0x18, 0x42, ZmodemConstants.zfin, 0]
        onSendData?(frame)
        state = .completed
        onCompletion?(.success(nil))
        cleanupSend()
    }

    private func sendCan() {
        let canSequence: [UInt8] = Array(repeating: ZmodemConstants.can, count: 8)
        onSendData?(canSequence)
        onSendData?(canSequence)
    }

    // MARK: - Helpers

    private func parseFileInfo(from data: [UInt8], offset: Int) -> ZmodemFileInfo? {
        guard offset < data.count else { return nil }
        // Skip 4-byte header padding + 0
        var idx = offset
        // Skip 4-byte size field if present (already consumed as part of header's 4 bytes)
        // The remaining bytes after header's trailing 0 contain NUL-separated fields
        // Find first NUL after offset
        // Our frame: [header][0][filename\0size\0...]
        // So data[offset] is first byte of filename block if header had 4 bytes+0
        // Search for next 0
        while idx < data.count, data[idx] == 0 { idx += 1 }
        guard idx < data.count else { return nil }
        let start = idx
        while idx < data.count, data[idx] != 0 { idx += 1 }
        let nameBytes = Array(data[start..<idx])
        let name = String(bytes: nameBytes, encoding: .utf8) ?? "unknown"
        // Size follows
        idx += 1
        var size: Int64 = 0
        if idx < data.count {
            let sizeStart = idx
            while idx < data.count, data[idx] != 0, data[idx] != 32 { idx += 1 }
            if sizeStart < idx {
                let sizeStr = String(bytes: Array(data[sizeStart..<idx]), encoding: .utf8) ?? ""
                size = Int64(sizeStr) ?? 0
            }
        }
        return ZmodemFileInfo(name: name, size: size, modificationDate: nil, mode: 0o644)
    }

    private func zdleEncode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            switch byte {
            case 0x18, 0x10, 0x11, 0x13, 0x90, 0x8D, 0x0D:
                out.append(0x18)
                out.append(byte ^ 0x40)
            default:
                out.append(byte)
            }
        }
        return out
    }

    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 { crc = (crc << 1) ^ 0x1021 } else { crc <<= 1 }
            }
        }
        return crc
    }

    private func cleanupSend() {
        sendFileHandle?.closeFile()
        sendFileHandle = nil
        sendOffset = 0
        sendFileSize = 0
    }

    private func cleanupReceive() {
        receiveFileHandle?.closeFile()
        receiveFileHandle = nil
        receiveFileURL = nil
        receiveBytesWritten = 0
        receiveFileSize = 0
    }

    deinit {
        cleanupSend()
        cleanupReceive()
    }
}
