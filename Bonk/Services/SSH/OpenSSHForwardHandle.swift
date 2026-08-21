#if os(macOS)
import Foundation

/// Lifetime handle for an OpenSSH forwarding process (extracted from OpenSSHBackend.swift).
final class OpenSSHForwardHandle: @unchecked Sendable {
    private let process: OpenSSHProcessTransport
    private let session: PTYSession

    init(process: OpenSSHProcessTransport, session: PTYSession) {
        self.process = process
        self.session = session
    }

    func waitUntilExit() async { _ = await process.waitForExit() }

    func close() {
        session.close()
        process.close()
    }
}
#endif
