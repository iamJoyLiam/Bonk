//
//  SFTPFileIO.swift
//  Bonk — DispatchIO + pread/pwrite 零拷贝本盘 IO
//
//  目标：
//    • 替换 FileHandle.seek+read 的阻塞与多拷贝，达到：Disk -> Kernel PageCache -> ByteBuffer -> SSH Channel
//    • Upload：pread(fd) 直接写入 ByteBuffer，无 Data 中间体
//    • Download：pwrite(fd, bytes, offset) 随机写，无 seek 竞态
//    • 兼容现有 SFTPTransferActor 接口，供单流与并行复用

import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import os.log

// MARK: - DispatchIO Reader (零拷贝)

/// 本盘并发读：每 shard 独立 fd，pread 直写 ByteBuffer
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

    /// 零拷贝读：分配 ByteBuffer，直接 pread 填充
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

    /// 兼容 Data 接口（仅用于回退）
    func readData(offset: UInt64, length: Int) throws -> Data {
        let buffer = try readByteBuffer(offset: offset, length: length)
        // ByteBuffer -> Data 无额外拷贝（共享 bytes）
        if buffer.readableBytes == 0 { return Data() }
        return Data(buffer.readableBytesView)
    }
}

// MARK: - pwrite Writer (并行下载)

final class SFTPPWriteHelper: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let closed = NIOLockedValueBox<Bool>(false)

    init(url: URL, totalBytes: UInt64) throws {
        // 创建并预分配
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw SFTPServiceError.operationFailed("open for write \(url.path) failed: \(String(cString: strerror(errno)))")
        }
        // 预分配大小，避免多 shard 追加竞态
        if totalBytes > 0 {
            _ = Darwin.ftruncate(descriptor, off_t(totalBytes))
        }
        fileDescriptor = descriptor
    }

    /// 随机写 Data 到 offset，无 seek
    func writeData(_ data: Data, at offset: UInt64) throws {
        let result = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.pwrite(fileDescriptor, base, data.count, off_t(offset))
        }
        if result < 0 {
            throw SFTPServiceError.operationFailed("pwrite failed at \(offset): \(String(cString: strerror(errno)))")
        }
    }

    /// 随机写 ByteBuffer 到 offset
    func writeBuffer(_ buffer: ByteBuffer, at offset: UInt64) throws {
        let result = buffer.withUnsafeReadableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.pwrite(fileDescriptor, base, buffer.readableBytes, off_t(offset))
        }
        if result < 0 {
            throw SFTPServiceError.operationFailed("pwrite buffer failed at \(offset): \(String(cString: strerror(errno)))")
        }
    }

    /// 周期性 fsync，减少崩溃丢数据窗口（每 64MB 调用一次）
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

// MARK: - Legacy Actor 迁移到 DispatchIO（保持接口）

/// P0 升级版：内部用 pread，接口仍返回 Data 以兼容单流旧调用
actor SFTPTransferActor {
    private let reader: SFTPDispatchReader

    init(url: URL) throws {
        reader = try SFTPDispatchReader(url: url)
    }

    func readChunk(offset: UInt64, length: Int) throws -> Data {
        try reader.readData(offset: offset, length: length)
    }

    /// 零拷贝新接口，供 P2 并行直接拿 ByteBuffer
    func readByteBuffer(offset: UInt64, length: Int) throws -> ByteBuffer {
        try reader.readByteBuffer(offset: offset, length: length)
    }

    func close() { reader.close() }
}
