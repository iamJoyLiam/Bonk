//
//  SessionManager+ControlSockets.swift
//  Bonk
//
//  Dead ControlMaster mux-socket pruning before a fresh connect.
//

import Foundation
import os.log

extension SessionManager {
    /// Best-effort prune of dead mux sockets for one host before a fresh
    /// manual connect. A socket whose master is wedged makes the new `ssh`
    /// hang on mux attach until ConnectTimeout; deleting a dead one is
    /// harmless (OpenSSH recreates it on demand). Sockets with a live master
    /// are kept, so fast multiplexed reconnects are unaffected. No-op when
    /// no socket file exists.
    static func pruneDeadControlSockets(username: String, host: String, port: UInt16) async {
        // Candidates under every naming scheme in use: current hashed naming
        // plus legacy FNV naming (exact paths), plus any stray
        // /tmp/bonk-ssh-*.sock leftovers (bypass-mode retry sockets).
        // NOTE: a bare user-host-port glob never matched the hashed paths,
        // so it silently no-op'd — hence the explicit list.
        var candidates = [
            SocketNaming.controlPath(host: host, port: port, username: username),
            SocketNaming.legacyPath(host: host, port: port, username: username),
        ]
        var globResult = glob_t()
        if glob("/tmp/bonk-ssh-*.sock", GLOB_NOSORT | GLOB_ERR, nil, &globResult) == 0 {
            defer { globfree(&globResult) }
            for index in 0 ..< globResult.gl_pathc {
                guard let pathPointer = globResult.gl_pathv[Int(index)] else { continue }
                let stray = String(cString: pathPointer)
                if !candidates.contains(stray) {
                    candidates.append(stray)
                }
            }
        }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if await !isMuxSocketAlive(path: path, username: username, host: host, port: port) {
                Log.session.info("[CONNECT] pruning dead mux socket \(path, privacy: .public)")
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// `ssh -O check` with a short timeout: a wedged master must not stall
    /// the connect path. Shared probe for every prune site.
    private static func isMuxSocketAlive(path: String, username: String, host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = ["-S", path, "-O", "check", "-p", String(port), "\(username)@\(host)"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: false)
                    return
                }
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                let ok = !process.isRunning && process.terminationStatus == 0
                if process.isRunning {
                    process.terminate()
                }
                continuation.resume(returning: ok)
            }
        }
    }
}
