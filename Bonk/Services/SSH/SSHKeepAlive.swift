@preconcurrency import Citadel
import Foundation
import os.log

/// L7 keepalive using lightweight SSH exec (echo).
actor SSHKeepAlive {
    private var keepaliveTask: Task<Void, Never>?
    private let interval: Duration = .seconds(30)
    private let maxMissed: Int = 3
    private var missedResponses: Int = 0

    /// Called when keepalive detects connection loss (3 consecutive failures).
    var onTimeout: (@Sendable () -> Void)?

    func start(client: SSHClient) {
        stop()
        keepaliveTask = Task { [weak client] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled else { break }
                guard let client else { break }

                if await self.checkAlive(client) {
                    self.missedResponses = 0
                } else {
                    self.missedResponses += 1
                    Log.ssh.warning("Keepalive missed (\(self.missedResponses)/\(self.maxMissed))")
                    if self.missedResponses >= self.maxMissed {
                        Log.ssh.error("Keepalive timeout — connection lost")
                        self.onTimeout?()
                        break
                    }
                }
            }
        }
    }

    /// One keepalive probe with a hard timeout. On a half-open connection
    /// (peer gone, NAT dropped) `executeCommand` can hang forever waiting for
    /// a channel response; the timeout turns that into a counted miss so the
    /// reconnect path actually fires.
    private func checkAlive(_ client: SSHClient) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await client.executeCommand("echo ok")
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func stop() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        missedResponses = 0
    }

    /// Set the timeout handler callback.
    func settimeoutHandler(_ handler: @escaping @Sendable () -> Void) {
        self.onTimeout = handler
    }
}
