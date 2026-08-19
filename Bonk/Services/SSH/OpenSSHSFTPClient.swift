//
//  OpenSSHSFTPClient.swift
//  Bonk
//
//  SFTP operations backed by the macOS system OpenSSH client.
//

#if os(macOS)

import Foundation
import os

/// SFTP command adapter for `/usr/bin/sftp`.
///
/// Each operation runs as a short-lived batch process. The process reuses the
/// terminal OpenSSH backend's ControlPath, so authentication and MFA are
/// shared without opening a second Citadel connection.
final class OpenSSHSFTPClient: @unchecked Sendable {
    private struct OperationState {
        var activeProcesses: [UUID: OpenSSHProcessTransport] = [:]
        var cancelledOperations: Set<UUID> = []
    }

    private let backend: OpenSSHBackend
    private let closed = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
    private let operationState = OSAllocatedUnfairLock<OperationState>(
        uncheckedState: OperationState()
    )

    init(backend: OpenSSHBackend) {
        self.backend = backend
    }

    var isActive: Bool {
        !closed.withLock { $0 }
    }

    func realPath() async throws -> String {
        let output = try await run(["pwd"])
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = line.range(of: "Remote working directory:") {
                let path = line[marker.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if path.hasPrefix("/") {
                    return path
                }
            }
            if line.hasPrefix("/") {
                return line
            }
        }
        throw SFTPServiceError.operationFailed("OpenSSH SFTP returned no remote path.")
    }

    func listDirectory(at path: String) async throws -> [SFTPFileEntry] {
        let output = try await run(["ls -l \(quote(path))"])
        let directory = normalizedPath(path)

        return output
            .components(separatedBy: .newlines)
            .compactMap { parseListingLine($0, directory: directory) }
    }

    func createDirectory(at path: String) async throws {
        _ = try await run(["mkdir \(quote(path))"])
    }

    func remove(at path: String, isDirectory: Bool) async throws {
        _ = try await run(["\(isDirectory ? "rmdir" : "rm") \(quote(path))"])
    }

    func upload(
        _ localURL: URL,
        to remotePath: String,
        operationID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let parser = ProgressParser()
        _ = try await run(
            ["put -p \(quote(localURL.path)) \(quote(remotePath))"],
            operationID: operationID,
            onOutput: { data in
                if let progress = parser.progress(from: data) {
                    onProgress(progress)
                }
            }
        )
    }

    func download(
        _ remotePath: String,
        to localURL: URL,
        operationID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let parser = ProgressParser()
        _ = try await run(
            ["get -p \(quote(remotePath)) \(quote(localURL.path))"],
            operationID: operationID,
            onOutput: { data in
                if let progress = parser.progress(from: data) {
                    onProgress(progress)
                }
            }
        )
    }

    func fileExists(at path: String) async -> Bool {
        do {
            _ = try await run(["ls -l \(quote(path))"])
            return true
        } catch {
            return false
        }
    }

    func close() {
        closed.withLock { $0 = true }
        let processes = operationState.withLock { state -> [OpenSSHProcessTransport] in
            let processes = Array(state.activeProcesses.values)
            state.activeProcesses.removeAll()
            state.cancelledOperations.removeAll()
            return processes
        }
        processes.forEach { $0.close() }
    }

    func cancel(operationID: UUID) {
        let process = operationState.withLock { state -> OpenSSHProcessTransport? in
            state.cancelledOperations.insert(operationID)
            return state.activeProcesses.removeValue(forKey: operationID)
        }
        process?.close()
    }

    private func run(
        _ commands: [String],
        operationID: UUID? = nil,
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) async throws -> String {
        let isClosed = closed.withLock { $0 }

        guard !isClosed else {
            throw SFTPServiceError.notConnected
        }
        guard commands.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            throw SFTPServiceError.operationFailed("Invalid OpenSSH SFTP command.")
        }

        if let operationID {
            operationState.withLock { state in
                state.cancelledOperations.remove(operationID)
                state.activeProcesses.removeValue(forKey: operationID)
            }
        }

        do {
            let output = try await backend.runSFTP(
                commands: commands,
                onOutput: onOutput,
                registerProcess: { [weak self] process in
                    guard let self, let operationID else { return }
                    self.register(process, for: operationID)
                }
            )
            if let operationID, consumeCancellation(for: operationID) {
                throw SFTPServiceError.transferCancelled
            }
            return output
        } catch {
            if let operationID, consumeCancellation(for: operationID) {
                throw SFTPServiceError.transferCancelled
            }
            throw error
        }
    }

    private func register(_ process: OpenSSHProcessTransport?, for operationID: UUID) {
        guard let process else {
            operationState.withLock { $0.activeProcesses.removeValue(forKey: operationID) }
            return
        }

        let shouldCancel = operationState.withLock { state in
            if state.cancelledOperations.contains(operationID) {
                return true
            }
            state.activeProcesses[operationID] = process
            return false
        }
        if shouldCancel {
            process.close()
        }
    }

    private func consumeCancellation(for operationID: UUID) -> Bool {
        operationState.withLock { $0.cancelledOperations.remove(operationID) != nil }
    }

    private func parseListingLine(_ rawLine: String, directory: String) -> SFTPFileEntry? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let fields = line.split(
            maxSplits: 8,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        guard fields.count == 9 else { return nil }

        let mode = String(fields[0])
        guard mode.count >= 10, "-dlcbps".contains(mode.first ?? " ") else { return nil }

        let rawName = String(fields[8])
        let name = rawName.components(separatedBy: " -> ").first ?? rawName
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let isDirectory = mode.first == "d"
        let path = pathJoin(directory, name)
        return SFTPFileEntry(
            id: path,
            name: name,
            path: path,
            isDirectory: isDirectory,
            size: UInt64(fields[4]) ?? 0,
            permissions: permissions(from: mode),
            modifiedAt: modifiedDate(
                month: String(fields[5]),
                day: String(fields[6]),
                timeOrYear: String(fields[7])
            ),
            longname: line
        )
    }

    private func permissions(from mode: String) -> UInt32 {
        let bits: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        var value: UInt32 = 0
        for (index, bit) in bits.enumerated() {
            let position = mode.index(mode.startIndex, offsetBy: index + 1)
            if mode[position] != "-" {
                value |= bit
            }
        }
        return value
    }

    private func modifiedDate(month: String, day: String, timeOrYear: String) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        let year: Int
        let format: String

        if let parsedYear = Int(timeOrYear) {
            year = parsedYear
            format = "MMM d yyyy"
        } else {
            year = calendar.component(.year, from: Date())
            format = "MMM d HH:mm yyyy"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        let value = Int(timeOrYear) == nil
            ? "\(month) \(day) \(timeOrYear) \(year)"
            : "\(month) \(day) \(timeOrYear)"
        return formatter.date(from: value)
    }

    private func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func normalizedPath(_ path: String) -> String {
        guard path.count > 1 else { return "/" }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func pathJoin(_ base: String, _ component: String) -> String {
        if base == "/" { return "/" + component }
        return base.hasSuffix("/") ? base + component : base + "/" + component
    }
}

private final class ProgressParser: @unchecked Sendable {
    private let buffer = OSAllocatedUnfairLock<String>(uncheckedState: "")
    private let regex = try? NSRegularExpression(pattern: #"\b([0-9]{1,3})%"#)

    func progress(from data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return nil
        }

        let value = buffer.withLock { current in
            current.append(text)
            if current.count > 2048 {
                current = String(current.suffix(1024))
            }
            return current
        }
        guard let regex else { return nil }

        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        guard let match = regex.matches(in: value, range: range).last,
              let percentRange = Range(match.range(at: 1), in: value),
              let percent = Double(value[percentRange])
        else {
            return nil
        }
        return min(max(percent / 100.0, 0), 1)
    }
}

#endif
