//
//  ZmodemHandler.swift
//  Bonk
//
//  Zmodem protocol handler for file transfer via terminal.
//  Supports sending and receiving files using ZRQINIT/ZRINIT handshake.
//

import Foundation
import os.log

// MARK: - Zmodem Constants

/// Zmodem protocol constants.
enum ZmodemConstants {
    /// Zmodem escape character
    static let zpad: UInt8 = 0x2A // '*'
    /// Zmodem escape sequence marker
    static let zesc: UInt8 = 0x1B // ESC
    /// CAN character for cancellation
    static let can: UInt8 = 0x18
    /// XON character
    static let xon: UInt8 = 0x11
    /// XOFF character
    static let xoff: UInt8 = 0x13

    /// Frame types
    static let zrqinit: UInt8 = 0x00 // Request init
    static let zrinit: UInt8 = 0x00 // Init response
    static let zrfile: UInt8 = 0x01 // File info
    static let zrpos: UInt8 = 0x02 // Position
    static let zdata: UInt8 = 0x03 // Data
    static let zeof: UInt8 = 0x04 // End of file
    static let zferr: UInt8 = 0x05 // File error
    static let zskip: UInt8 = 0x06 // Skip file
    static let znak: UInt8 = 0x07 // NAK
    static let zabort: UInt8 = 0x08 // Abort
    static let zfin: UInt8 = 0x09 // Finish
    static let zrpsi: UInt8 = 0x0A // Protocol selection
    static let zrchange: UInt8 = 0x0B // Change directory
}

// MARK: - Zmodem State

/// Zmodem transfer state.
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

/// Information about a file being transferred.
struct ZmodemFileInfo {
    let name: String
    let size: Int64
    let modificationDate: Date?
    let mode: Int32
}

// MARK: - Zmodem Handler Delegate

/// Delegate for Zmodem events.
protocol ZmodemHandlerDelegate: AnyObject {
    func zmodemDidStartTransfer(_ file: ZmodemFileInfo)
    func zmodemDidUpdateProgress(_ progress: Double)
    func zmodemDidCompleteTransfer(_ file: ZmodemFileInfo)
    func zmodemDidFailWithError(_ error: Error)
    func zmodemDidCancel()
    func zmodemDidRequestFileSelection() -> [URL]?
}

// MARK: - Zmodem Handler

/// Handles Zmodem file transfer protocol.
class ZmodemHandler {
    private let logger = Logger(subsystem: "com.bonk", category: "Zmodem")

    /// Current transfer state.
    private(set) var state: ZmodemState = .idle

    /// Delegate for callbacks.
    weak var delegate: ZmodemHandlerDelegate?

    /// Output buffer for sending data to terminal.
    var onSendData: (([UInt8]) -> Void)?

    /// Received file data accumulator.
    private var receivedData = Data()

    /// Current file info being received.
    private var currentFile: ZmodemFileInfo?

    /// Files to send.
    private var filesToSend: [URL] = []

    /// Current file index being sent.
    private var currentFileIndex = 0

    // MARK: - Public API

    /// Start receiving files (called when terminal detects ZRQINIT).
    func startReceive() {
        logger.info("Starting Zmodem receive")
        state = .waitingForInit
        sendZrinit()
    }

    /// Start sending files.
    func startSend(files: [URL]) {
        logger.info("Starting Zmodem send with \(files.count) files")
        filesToSend = files
        currentFileIndex = 0
        state = .sendingFile

        if let firstFile = files.first {
            sendZrqinit()
            _ = delegate?.zmodemDidRequestFileSelection()
        }
    }

    /// Cancel current transfer.
    func cancel() {
        logger.info("Cancelling Zmodem transfer")
        state = .cancelled
        sendCan()
        delegate?.zmodemDidCancel()
    }

    /// Process incoming data from terminal.
    func processData(_ data: [UInt8]) {
        guard !data.isEmpty else { return }

        // Check for Zmodem initiation sequence
        if data.count >= 2, data[0] == ZmodemConstants.zpad, data[1] == ZmodemConstants.zpad {
            handleZmodemFrame(data)
        }
    }

    // MARK: - Frame Handling

    private func handleZmodemFrame(_ data: [UInt8]) {
        guard data.count > 2 else { return }

        // Skip padding
        var index = 0
        while index < data.count, data[index] == ZmodemConstants.zpad {
            index += 1
        }

        // Skip 'B' marker if present
        if index < data.count, data[index] == 0x42 { // 'B'
            index += 1
        }

        guard index < data.count else { return }

        let frameType = data[index]
        index += 1

        switch frameType {
        case ZmodemConstants.zrqinit:
            handleZrqinit()
        case ZmodemConstants.zrinit:
            handleZrinit()
        case ZmodemConstants.zrfile:
            handleZrfile(data: data, offset: index)
        case ZmodemConstants.zeof:
            handleZeof()
        case ZmodemConstants.zfin:
            handleZfin()
        case ZmodemConstants.zrpos:
            handleZrpos(data: data, offset: index)
        default:
            logger.warning("Unknown frame type: \(frameType)")
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
        // Send file if we have files to send
        if currentFileIndex < filesToSend.count {
            sendNextFile()
        }
    }

    private func handleZrfile(data: [UInt8], offset: Int) {
        logger.info("Received ZRFILE - file info")
        // Parse filename and size from frame data
        // For now, send ZRPOS to acknowledge
        sendZrpos()
    }

    private func handleZeof() {
        logger.info("Received ZEOF - end of file")
        // Send ZRINIT to receive next file or ZFIN to complete
        sendZrinit()
    }

    private func handleZfin() {
        logger.info("Received ZFIN - transfer complete")
        state = .completed
        delegate?.zmodemDidCompleteTransfer(currentFile ?? ZmodemFileInfo(name: "", size: 0, modificationDate: nil, mode: 0o644))
    }

    private func handleZrpos(data: [UInt8], offset: Int) {
        logger.info("Received ZRPOS - position confirmed")
        // Send next data frame
        sendNextDataChunk()
    }

    // MARK: - Frame Sending

    private func sendZrqinit() {
        var frame: [UInt8] = [ZmodemConstants.zpad, ZmodemConstants.zesc, 0x42] // * ESC B
        frame.append(ZmodemConstants.zrqinit)
        frame.append(contentsOf: [0, 0, 0, 0]) // File size placeholder
        frame.append(0) // Trailing zero
        onSendData?(frame)
    }

    private func sendZrinit() {
        var frame: [UInt8] = [ZmodemConstants.zpad, ZmodemConstants.zesc, 0x42]
        frame.append(ZmodemConstants.zrinit)
        frame.append(contentsOf: [0, 0, 0, 0]) // Options
        frame.append(0)
        onSendData?(frame)
    }

    private func sendZrpos() {
        var frame: [UInt8] = [ZmodemConstants.zpad, ZmodemConstants.zesc, 0x42]
        frame.append(ZmodemConstants.zrpos)
        frame.append(contentsOf: [0, 0, 0, 0]) // Position
        frame.append(0)
        onSendData?(frame)
    }

    private func sendZrfile(_ file: ZmodemFileInfo) {
        var frame: [UInt8] = [ZmodemConstants.zpad, ZmodemConstants.zesc, 0x42]
        frame.append(ZmodemConstants.zrfile)
        // File size (little-endian)
        var size = UInt32(file.size)
        frame.append(contentsOf: withUnsafeBytes(of: &size) { Array($0) })
        frame.append(0) // Trailing zero
        // Filename
        frame.append(contentsOf: file.name.utf8)
        frame.append(0)
        onSendData?(frame)
    }

    private func sendNextFile() {
        guard currentFileIndex < filesToSend.count else {
            sendZfin()
            return
        }

        let fileURL = filesToSend[currentFileIndex]
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: fileURL.path) else {
            logger.error("File not found: \(fileURL.path)")
            currentFileIndex += 1
            sendNextFile()
            return
        }

        let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let size = attrs?[.size] as? Int64 ?? 0
        let modDate = attrs?[.modificationDate] as? Date

        let fileInfo = ZmodemFileInfo(
            name: fileURL.lastPathComponent,
            size: size,
            modificationDate: modDate,
            mode: 0o644
        )
        currentFile = fileInfo

        delegate?.zmodemDidStartTransfer(fileInfo)
        sendZrfile(fileInfo)
    }

    private func sendNextDataChunk() {
        // TODO: Implement data frame sending
        logger.info("Sending data chunk (not implemented)")
    }

    private func sendZfin() {
        var frame: [UInt8] = [ZmodemConstants.zpad, ZmodemConstants.zesc, 0x42]
        frame.append(ZmodemConstants.zfin)
        frame.append(0)
        onSendData?(frame)
    }

    private func sendCan() {
        // Send multiple CAN characters to abort
        let canSequence: [UInt8] = Array(repeating: ZmodemConstants.can, count: 5)
        onSendData?(canSequence)
    }
}
