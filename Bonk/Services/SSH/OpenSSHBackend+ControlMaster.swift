#if os(macOS)
    import Foundation

    // MARK: - ControlMaster & known_hosts (extracted)

    extension OpenSSHBackend {
        /// Kill leftover `bonk-ssh` mux processes and stale control sockets at launch.
        static func cleanupOrphanedMuxes() {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [
                "-c",
                "pkill -9 -f 'bonk-ssh-.*\\.sock' 2>/dev/null; "
                    + "rm -f /tmp/bonk-ssh-*.sock 2>/dev/null",
            ]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()
        }

        static func prepareKnownHostsPath() throws -> String {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Bonk", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let path = support.appendingPathComponent("known_hosts").path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
                _ = chmod(path, mode_t(0o600))
            }
            return path
        }

        func closeControlMaster() {
            guard FileManager.default.fileExists(atPath: controlPath) else { return }
            // Never block the caller (often MainActor) on `ssh -O exit`: a
            // wedged master would freeze the UI, making the tab X feel dead.
            // Exit async with a short timeout and reap afterwards; a concurrent
            // fresh connect is protected by the pre-connect dead-socket prune.
            let path = controlPath
            let port = config.port
            let username = config.username
            let host = config.host
            Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = [
                    "-S", path,
                    "-O", "exit",
                    "-p", String(port),
                    "\(username)@\(host)",
                ]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                guard (try? process.run()) != nil else {
                    try? FileManager.default.removeItem(atPath: path)
                    return
                }
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    process.terminate()
                }
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        /// Liveness probe for Wake recovery - checks ControlMaster without creating new channel.
        /// Returns true if ControlMaster is alive, false otherwise.
        /// Used only on Wake/suspicious, not every 30s (per P0 spec).
        func checkControlMasterLiveness() async -> Bool {
            guard FileManager.default.fileExists(atPath: controlPath) else { return false }
            return await withCheckedContinuation { continuation in
                Task.detached(priority: .utility) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = [
                        "-S", self.controlPath,
                        "-O", "check",
                        "-p", String(self.config.port),
                        "\(self.config.username)@\(self.config.host)",
                    ]
                    process.standardOutput = Pipe()
                    process.standardError = Pipe()
                    do {
                        try process.run()
                        process.waitUntilExit()
                        continuation.resume(returning: process.terminationStatus == 0)
                    } catch {
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }
#endif
