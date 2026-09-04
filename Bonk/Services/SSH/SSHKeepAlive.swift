@preconcurrency import Citadel
import Foundation
import os.log

/// L7 keepalive — Lightweight probe (original `echo ok` creates channel each time, too heavy)
/// Ideal is `SSH_MSG_IGNORE` / `keepalive@openssh.com` global request, not exposed by Citadel's NIOSSHHandler.sendGlobalRequestMessage
/// Fallback: fast-path check `channel.isActive`, then use `true` (no output) + 5s timeout to avoid `echo` PTY echo and output copy
actor SSHKeepAlive {
    private var keepaliveTask: Task<Void, Never>?
    /// 15s × 3 misses ≈ 45-60s to detect an idle drop — must beat typical
    /// sshd ClientAliveInterval so recovery starts before the user types.
    private let interval: Duration = .seconds(15)
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

    /// Lightweight probe: check TCP channel liveness first, then send lightest exec (`true` no output)
    /// Half-open (NAT drop) exec will hang, use 5s timeout to convert to miss and trigger reconnect
    private func checkAlive(_ client: SSHClient) async -> Bool {
        // Fast-path: TCP channel dead, directly miss to avoid new channel
        if !client.isConnected { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    // `true` lighter than `echo ok`: no output, no PTY echo, server returns exit 0 only
                    _ = try await client.executeCommand("true")
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
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