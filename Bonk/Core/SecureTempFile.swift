//
//  SecureTempFile.swift
//  Bonk
//
//  Temporary files that hold credential material (askpass secrets, private
//  keys). The previous pattern was:
//
//      Data.write(to: url, options: [.atomic])   // created with the umask
//      chmod(path, 0o600)                        // narrowed afterwards
//
//  That leaves a window in which the secret sits on disk world-readable under
//  a default 022 umask, and a crash before `chmod` leaves it that way
//  permanently. Here the file is created with `O_CREAT | O_EXCL` and mode
//  0600 atomically, so there is no window to race and no leftover state to
//  clean up on the success path.
//

import Foundation
import os.log

/// A file in the per-user temporary directory created with owner-only
/// permissions, whose contents are credential material.
struct SecureTempFile {
    let url: URL

    var path: String { url.path }

    /// Create `contents` at `name` with mode 0600.
    ///
    /// `O_EXCL` means we never adopt a pre-existing file: a planted symlink
    /// or a leftover from an earlier run cannot be written through. The mode
    /// is part of the `open` call, so the secret is never briefly 0644.
    static func create(name: String, contents: Data) throws -> SecureTempFile {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let target = dir.appendingPathComponent(name, isDirectory: false)

        // Refuse to follow a symlink at the final path component.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
            throw SecureTempFileError.unsafeDestination(target.path)
        }

        let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            throw SecureTempFileError.createFailed(target.path, errno)
        }
        // Defence in depth: O_EXCL already guarantees we created it, but a
        // permissive umask must never widen the mode we asked for.
        _ = fchmod(fd, mode_t(0o600))
        defer { Darwin.close(fd) }

        do {
            try contents.write(to: fd)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return SecureTempFile(url: target)
    }

    /// Overwrite the contents in place without changing the inode or mode.
    /// Used for the askpass secret, which is rewritten per attempt.
    func write(_ contents: Data) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_TRUNC | O_NOFOLLOW)
        guard fd >= 0 else { throw SecureTempFileError.createFailed(url.path, errno) }
        defer { Darwin.close(fd) }
        _ = fchmod(fd, mode_t(0o600))
        try contents.write(to: fd)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum SecureTempFileError: Error {
    case createFailed(String, Int32)
    case unsafeDestination(String)
}

/// Removes leftover credential files from earlier runs.
///
/// A crash between `create` and `remove` leaves plaintext secrets in the
/// temporary directory. Nothing can remove a file at the instant the process
/// dies, so recovery has to happen on the next launch instead: the naming
/// scheme is ours and the files are never legitimately reused.
enum SecureTempFileSweeper {
    private static let prefixes = ["bonk-ssh-askpass-", "bonk-ssh-"]

    /// Delete stale files older than `maxAge` so a concurrent connection in
    /// another process is never disturbed.
    static func sweepStale(maxAge: TimeInterval = 60 * 60) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
            // Control sockets are cleaned by their own owner; only sweep the
            // credential-bearing extensions.
            guard name.hasSuffix(".secret") || name.hasSuffix(".key") || name.hasSuffix(".cert")
                    || name.contains("askpass-") else { continue }
            let url = dir.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private extension Data {
    /// `Data.write(to:)` on a raw descriptor, used so the file is never
    /// re-opened by path (which would re-traverse a replaced symlink).
    func write(to fd: Int32) throws {
        try withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SecureTempFileError.createFailed("fd \(fd)", errno)
                }
                offset += written
            }
        }
    }
}
