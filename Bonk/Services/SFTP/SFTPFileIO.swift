//
//  SFTPFileIO.swift
// Bonk — DispatchIO + pread/pwrite  IO
//
//  
// •  FileHandle.seek+read ，：Disk -> Kernel PageCache -> ByteBuffer -> SSH Channel
// • Upload：preadfd  ByteBuffer， Data
// • Download：pwritefd, bytes, offset ， seek
// •  SFTPTransferActor ，

import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import os.log

// MARK: - DispatchIO Reader

// / ： shard  fd，pread  ByteBuffer
final class SFTPDispatchReader: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let closed = NIOLockedValueBox<Bool>(false)

    init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw SFTPServiceError.operationFailed("open \(url.path) failed: \(String(cString: strerror(errno)))")
        }
        fileDescriptor = descriptor
    }

    deinit {
        if !closed.withLockedValue({ $0 }) { Darwin.close(fileDescriptor) }
    }

    func close() {
        let shouldClose = closed.withLockedValue { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        if shouldClose { Darwin.close(fileDescriptor) }
    }

    // / ： ByteBuffer， pread
    func readByteBuffer(offset: UInt64, length: Int) throws -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: length)
        let bytesRead = try buffer.withUnsafeMutableWritableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            let result = Darwin.pread(fileDescriptor, base, length, off_t(offset))
            if result < 0 {
                throw SFTPServiceError.operationFailed("pread failed at \(offset): \(String(cString: strerror(errno)))")
            }
            return result
        }
        buffer.moveWriterIndex(forwardBy: bytesRead)
        return buffer
    }

    // /  Data
    func readData(offset: UInt64, length: Int) throws -> Data {
        let buffer = try readByteBuffer(offset: offset, length: length)
        // ByteBuffer -> Data  bytes
        if buffer.readableBytes == 0 { return Data() }
        return Data(buffer.readableBytesView)
    }
}

// MARK: - pwrite Writer

final class SFTPPWriteHelper: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let closed = NIOLockedValueBox<Bool>(false)

    init(url: URL, totalBytes: UInt64) throws {
        // Preallocate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw SFTPServiceError.operationFailed("open for write \(url.path) failed: \(String(cString: strerror(errno)))")
        }
        // Preallocate， shard
        if totalBytes > 0 {
            _ = Darwin.ftruncate(descriptor, off_t(totalBytes))
        }
        fileDescriptor = descriptor
    }

    // /  Data  offset， seek
    func writeData(_ data: Data, at offset: UInt64) throws {
        let result = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.pwrite(fileDescriptor, base, data.count, off_t(offset))
        }
        if result < 0 {
            throw SFTPServiceError.operationFailed("pwrite failed at \(offset): \(String(cString: strerror(errno)))")
        }
    }

    // /  ByteBuffer  offset
    func writeBuffer(_ buffer: ByteBuffer, at offset: UInt64) throws {
        let result = buffer.withUnsafeReadableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.pwrite(fileDescriptor, base, buffer.readableBytes, off_t(offset))
        }
        if result < 0 {
            throw SFTPServiceError.operationFailed("pwrite buffer failed at \(offset): \(String(cString: strerror(errno)))")
        }
    }

    // /  fsync， 64MB
    func sync() {
        _ = Darwin.fsync(fileDescriptor)
    }

    func close() {
        let shouldClose = closed.withLockedValue { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        if shouldClose { Darwin.close(fileDescriptor) }
    }

    deinit {
        if !closed.withLockedValue({ $0 }) { Darwin.close(fileDescriptor) }
    }
}

// MARK: - Legacy Actor  DispatchIO

// / P0 ： pread， Data
actor SFTPTransferActor {
    private let reader: SFTPDispatchReader

    init(url: URL) throws {
        reader = try SFTPDispatchReader(url: url)
    }

    func readChunk(offset: UInt64, length: Int) throws -> Data {
        try reader.readData(offset: offset, length: length)
    }

    // / ， P2  ByteBuffer
    func readByteBuffer(offset: UInt64, length: Int) throws -> ByteBuffer {
        try reader.readByteBuffer(offset: offset, length: length)
    }

    func close() { reader.close() }
}
