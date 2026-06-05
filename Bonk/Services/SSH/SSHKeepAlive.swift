@preconcurrency import Citadel
import Foundation
import os.log

/// L7 keepalive using lightweight SSH exec (echo).
actor SSHKeepAlive {
    private var keepaliveTask: Task<Void, Never>?
    private let interval: Duration = .seconds(30)
    private let maxMissed: Int = 3
    private var missedResponses: Int = 0

    func start(client: SSHClient) {
        stop()
        keepaliveTask = Task { [weak client] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled else { break }
                guard let client else { break }

                do {
                    _ = try await client.executeCommand("echo ok")
                    self.missedResponses = 0
                } catch {
                    self.missedResponses += 1
                    Log.ssh.warning("Keepalive missed (\(self.missedResponses)/\(self.maxMissed))")
                    if self.missedResponses >= self.maxMissed {
                        Log.ssh.error("Keepalive timeout — connection lost")
                        break
                    }
                }
            }
        }
    }

    func stop() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        missedResponses = 0
    }
}
