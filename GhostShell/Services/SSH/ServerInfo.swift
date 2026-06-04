//
//  ServerInfo.swift
//  GhostShell
//
//  Server system info fetched via SSH exec.
//

import Foundation
import os.log

/// System information fetched from the remote server.
struct ServerInfo {
    var hostname: String?
    var os: String?
    var kernel: String?
    var architecture: String?
    var uptime: String?
    var cpuModel: String?
    var cpuCores: String?
    var memoryUsed: String?
    var diskUsed: String?
    var loadAverage: String?
    var serverIP: String?
    var shell: String?
}

/// Fetches server info via a single SSH exec command.
enum ServerInfoFetcher {

    /// Simple shell script using only basic echo/pipes. No herestrings, no read -r.
    private static let script = [
        "echo hostname=$(hostname)",
        "echo kernel=$(uname -r)",
        "echo arch=$(uname -m)",
        "echo shell=$SHELL",
        // OS
        "if [ -f /etc/os-release ]; then . /etc/os-release && echo os=$PRETTY_NAME; elif command -v sw_vers >/dev/null 2>&1; then echo os=$(sw_vers -productName) $(sw_vers -productVersion); else echo os=$(uname -s); fi",
        // Uptime
        "echo uptime=$(uptime 2>/dev/null | sed 's/.*up //' | sed 's/, [0-9]* user.*//' | sed 's/^ *//')",
        // CPU
        "if command -v lscpu >/dev/null 2>&1; then echo cpu=$(lscpu 2>/dev/null | grep 'Model name' | sed 's/.*: *//'); echo cores=$(nproc 2>/dev/null); else echo cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null); echo cores=$(sysctl -n hw.ncpu 2>/dev/null); fi",
        // Memory (free -h)
        "if command -v free >/dev/null 2>&1; then echo mem=$(free -h 2>/dev/null | awk '/Mem:/{print $3\"/\"$2}'); else echo mem=$(($(sysctl -n hw.memsize 2>/dev/null)/1024/1024))MB; fi",
        // Disk
        "echo disk=$(df -h / 2>/dev/null | tail -1 | awk '{print $3\"/\"$2}')",
        // Load
        "if [ -f /proc/loadavg ]; then echo load=$(cat /proc/loadavg | awk '{print $1, $2, $3}'); else echo load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'); fi",
        // IP
        "echo ip=$(hostname -I 2>/dev/null | awk '{print $1}')",
    ].joined(separator: "; ")

    /// Fetch server info from an SSH connection. Returns nil on failure.
    static func fetch(using sshService: SSHNetworkService) async -> ServerInfo? {
        let cmd = "(\(script))"
        guard let output = try? await sshService.executeCommand(cmd) else {
            Log.ssh.warning("Server info fetch failed")
            return nil
        }
        return parseOutput(output)
    }

    /// Parse key=value output into ServerInfo. Extracted for testability.
    static func parseOutput(_ output: String) -> ServerInfo {
        var info = ServerInfo()
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex])
            let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "hostname": info.hostname = value
            case "os":       info.os = value
            case "kernel":   info.kernel = value
            case "arch":     info.architecture = value
            case "uptime":   info.uptime = value
            case "cpu":      info.cpuModel = value
            case "cores":    info.cpuCores = value
            case "mem":      info.memoryUsed = value
            case "disk":     info.diskUsed = value
            case "load":     info.loadAverage = value
            case "ip":       info.serverIP = value
            case "shell":    info.shell = value
            default: break
            }
        }
        return info
    }
}
