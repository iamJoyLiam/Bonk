//
//  OpenSSHProcessTransport.swift
//  Bonk
//
//  macOS process-backed transport for the system OpenSSH client.
//

#if os(macOS)

import Darwin
import Foundation

/// Swift 6 marks `fork()` unavailable; this shim is deliberate.
@_silgen_name("fork")
private func rawfork() -> pid_t

/// Owns a PTY master fd and its child process.
///
/// PTY is required for OpenSSH password and keyboard-interactive prompts.
/// Transport owns fd/process; `PTYSession` only reads, writes, and resizes it.
final class OpenSSHProcessTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var _masterFD: Int32
    private let pid: pid_t
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []

    var masterFD: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return _masterFD
    }

    private init(pid: pid_t, masterFD: Int32) {
        self.pid = pid
        _masterFD = masterFD
    }

    /// Spawn arbitrary executable inside a real controlling PTY.
    static func spawn(
        executable: String,
        arguments: [String],
        cols: Int = 120,
        rows: Int = 40,
        termType: String = "xterm-256color"
    ) throws -> OpenSSHProcessTransport {
        guard !executable.isEmpty else {
            throw SSHServiceError.connectionFailed("OpenSSH executable is empty.")
        }

        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize()
        size.ws_col = UInt16(max(1, min(cols, 500)))
        size.ws_row = UInt16(max(1, min(rows, 200)))

        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw SSHServiceError.connectionFailed(
                "Failed to allocate PTY: \(String(cString: strerror(errno)))"
            )
        }

        let argv = ([executable] + arguments).compactMap { strdup($0) }
        let pid = rawfork()

        if pid == 0 {
            Darwin.close(master)
            guard login_tty(slave) == 0 else { _exit(127) }
            _ = termType.withCString { setenv("TERM", $0, 1) }

            var cargs: [UnsafeMutablePointer<CChar>?] = argv
            cargs.append(nil)
            execv(executable, &cargs)
            _exit(127)
        }

        Darwin.close(slave)
        argv.forEach { free($0) }

        guard pid > 0 else {
            Darwin.close(master)
            throw SSHServiceError.connectionFailed(
                "Failed to spawn \(executable): \(String(cString: strerror(errno)))"
            )
        }

        let transport = OpenSSHProcessTransport(pid: pid, masterFD: master)
        transport.reapWhenExited()
        return transport
    }

    /// Write raw bytes to child PTY.
    func write(_ data: Data) throws {
        let fd = masterFD
        guard fd >= 0 else {
            throw SSHServiceError.connectionFailed("OpenSSH PTY is closed.")
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SSHServiceError.connectionFailed(
                        "OpenSSH PTY write failed: \(String(cString: strerror(errno)))"
                    )
                }
                offset += written
            }
        }
    }

    /// Wait for child exit. Safe to call more than once.
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Close PTY and terminate child.
    func close() {
        lock.lock()
        let fd = _masterFD
        _masterFD = -1
        let child = pid
        lock.unlock()

        if fd >= 0 { Darwin.close(fd) }
        if child > 0 { kill(child, SIGHUP) }
    }

    private func reapWhenExited() {
        let child = pid
        Task.detached(priority: .utility) { [weak self] in
            var status: Int32 = 0
            _ = waitpid(child, &status, 0)
            self?.finishExit(status)
        }
    }

    private func finishExit(_ status: Int32) {
        let signal = status & 0x7f
        let normalizedStatus: Int32
        if signal == 0 {
            normalizedStatus = (status >> 8) & 0xff
        } else if signal != 0x7f {
            normalizedStatus = 128 + signal
        } else {
            normalizedStatus = status
        }

        lock.lock()
        exitStatus = normalizedStatus
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: status) }
    }
}

#endif
