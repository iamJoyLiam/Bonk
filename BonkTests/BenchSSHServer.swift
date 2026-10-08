import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Citadel
@testable import Bonk

/// A real SSH server, in process, for host-key trust tests.
///
/// ## What this is for
///
/// It exists so that host-key trust can be tested against a *real* SSH server
/// and a *real* `/usr/bin/ssh`, rather than against a reconstruction of what
/// the client is assumed to do. `/usr/bin/ssh` and `/usr/bin/sftp` connect to it
/// over TCP exactly as they would to any other server, which is what makes
/// AUDIT-FIND-001's behavioural gate possible.
///
/// ## What this is deliberately not
///
/// `BenchSFTPDelegate` is **not** a general-purpose SFTP server. Only `realPath`
/// answers; every other operation fails. That is sufficient because the security
/// decision under test happens during host-key validation, which is strictly
/// before any filesystem operation. Do not grow this into a file-serving fixture
/// without reading this again — a delegate that silently half-works will produce
/// tests that pass for the wrong reason.
///
/// ## Environment safety
///
/// It touches nothing of the user's: no `~/.ssh/known_hosts`, no system SSH
/// configuration, no fixed external port. Ports are claimed from a private range
/// via the same allocator the other fixtures use, and the host key is derived
/// from an injected seed in a throwaway `UserDefaults` suite.
enum BenchSSHServer {
    /// Port range, deliberately distinct from the other fixtures' ranges so a
    /// parallel suite cannot collide with this one.
    static let ports: ClosedRange<UInt16> = 25_300 ... 25_379

    /// A running server. Hold this for the duration of the test; `stop()` releases
    /// both the listener and the event loop group it owns.
    final class Instance {
        let port: Int
        private var server: SSHServer?
        private var group: MultiThreadedEventLoopGroup?

        init(port: Int, server: SSHServer, group: MultiThreadedEventLoopGroup) {
            self.port = port
            self.server = server
            self.group = group
        }

        /// Same shape as the other fixtures' `stop()`: hand ownership to a detached
        /// `Task` via `UncheckedSendable` rather than awaiting `close()` across the
        /// isolation boundary, which the compiler correctly refuses.
        func stop() {
            let server = server
            let group = group
            self.server = nil
            self.group = nil
            let handle = server.map(UncheckedSendable.init)
            Task {
                try? await handle?.value.close()
                try? await group?.shutdownGracefully()
            }
        }
    }

    /// Host keys are derived from `hostKeySeed`, so two different byte values give
    /// two different keys. That is the whole mechanism behind "trusted A, then
    /// the server presents B": no key rotation logic, just a different seed.
    @discardableResult
    static func start(
        hostKeySeed: UInt8,
        password: String,
        execDelegate: ExecDelegate? = nil,
        sftpDelegate: SFTPDelegate? = nil
    ) async throws -> Instance {
        guard let requested = SSHFixturePort.claim(in: ports) else {
            throw BenchSSHServerError.noFreePort
        }
        return try await start(
            hostKeySeed: hostKeySeed, password: password,
            port: Int(requested), execDelegate: execDelegate, sftpDelegate: sftpDelegate
        )
    }

    /// Explicit-port form. A host key is only "changed" from ssh's point of view
    /// when the same `host:port` presents a different key, so a test that needs
    /// to compare two keys must reuse the port rather than claim a second one.
    @discardableResult
    static func start(
        hostKeySeed: UInt8,
        password: String,
        port: Int,
        execDelegate: ExecDelegate? = nil,
        sftpDelegate: SFTPDelegate? = nil
    ) async throws -> Instance {
        let requested = UInt16(port)

        let suite = "com.bonk.tests.bench.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = TeamHostKeyStore(defaults: defaults)
        store.injectSeed(Data(repeating: hostKeySeed, count: 32))
        guard let hostKey = store.loadOrCreateHostKey() else {
            throw BenchSSHServerError.noHostKey
        }

        // A fresh group per server, because reusing one after a failed bind
        // would make a retry depend on state the failed attempt left behind.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let server = try await SSHServer.host(
                host: "127.0.0.1",
                port: Int(requested),
                hostKeys: [hostKey],
                authenticationDelegate: TestPasswordAuthDelegate(password: password),
                group: group
            )
            if let execDelegate { server.enableExec(withDelegate: execDelegate) }
            if let sftpDelegate { server.enableSFTP(withDelegate: sftpDelegate) }
            return Instance(port: Int(requested), server: server, group: group)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    enum BenchSSHServerError: Error {
        case noFreePort
        case noHostKey
    }
}

/// Minimal SFTP surface. See `BenchSSHServer` for why this is not a real server.
///
/// `realPath` answers with a single fixed component so a client that *does* get
/// past host-key validation can complete its initial handshake and the test can
/// distinguish "rejected on trust" from "reached the filesystem".
struct BenchSFTPDelegate: SFTPDelegate {
    static let root = "/"

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        var attributes = SFTPFileAttributes()
        attributes.permissions = 0o755
        return attributes
    }

    func openFile(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        flags: SFTPOpenFileFlags,
        context: SSHContext
    ) async throws -> Citadel.SFTPFileHandle {
        throw BenchSFTPDelegateError.unsupported
    }

    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        .failure
    }

    func createDirectory(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        .failure
    }

    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        .failure
    }

    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        var attributes = SFTPFileAttributes()
        attributes.permissions = 0o755
        return [SFTPPathComponent(filename: Self.root, longname: Self.root, attributes: attributes)]
    }

    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        BenchEmptyDirectoryHandle()
    }

    func setFileAttributes(
        to attributes: SFTPFileAttributes,
        atPath path: String,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        .failure
    }

    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode {
        .failure
    }

    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        throw BenchSFTPDelegateError.unsupported
    }

    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode {
        .failure
    }
}

/// `SFTPStatusCode` is not an `Error`, so the methods that must throw rather
/// than return a code throw this instead.
enum BenchSFTPDelegateError: Error { case unsupported }

/// Empty listing, and the reason it is empty: nothing is served.
struct BenchEmptyDirectoryHandle: SFTPDirectoryHandle {
    func listFiles(context: SSHContext) async throws -> [SFTPFileListing] { [] }
}
