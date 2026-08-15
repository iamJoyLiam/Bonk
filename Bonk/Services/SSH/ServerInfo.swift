//
//  ServerInfo.swift
//  Bonk
//
//  Server system info fetched via SSH exec.
//

import Foundation
import os.log

/// System information fetched from the remote server.
struct ServerInfo: Equatable {
    var hostname: String?
    var os: String?
    var kernel: String?
    var architecture: String?
    var cpuModel: String?
    var cpuCores: String?
    var memoryUsed: String?
    var diskUsed: String?
    var loadAverage: String?
    var serverIP: String?
    var shell: String?
    var uptimeSeconds: UInt64?

    // Numeric fields for the toolbar resource indicator.
    var cpuUsagePercent: Double?
    var memUsedBytes: UInt64?
    var memTotalBytes: UInt64?
    var diskUsedBytes: UInt64?
    var diskTotalBytes: UInt64?
    var swapUsedBytes: UInt64?
    var swapTotalBytes: UInt64?
    var networkRXBytes: UInt64?
    var networkTXBytes: UInt64?
    var networkRXRateBps: Double?
    var networkTXRateBps: Double?
    var diskReadBytes: UInt64?
    var diskWriteBytes: UInt64?
    var diskReadRateBps: Double?
    var diskWriteRateBps: Double?
    var cpuTempCelsius: Double?
    var topProcesses: String?
    var listenPorts: String?
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
        "if [ -f /etc/os-release ]; then . /etc/os-release && echo os=$PRETTY_NAME; "
            + "elif command -v sw_vers >/dev/null 2>&1; then "
            + "echo os=$(sw_vers -productName) $(sw_vers -productVersion); else echo os=$(uname -s); fi",
        // Uptime — seconds since boot, normalized across Linux / macOS
        "if [ -f /proc/uptime ]; then "
            + "echo uptime_seconds=$(awk '{print int($1)}' /proc/uptime); "
            + "elif [ \"$(uname -s)\" = \"Darwin\" ]; then "
            + "boot=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*{ *sec = \\([0-9]*\\).*/\\1/'); "
            + "now=$(date +%s); echo uptime_seconds=$((now-boot)); "
            + "else echo uptime_seconds=$(uptime 2>/dev/null | sed 's/.*up //' | awk -F'[ ,]' '{if ($2==\"min\") print $1*60; else if ($2==\"days\") print $1*86400; else print $1*60}'); fi",
        // CPU
        "if command -v lscpu >/dev/null 2>&1; then "
            + "echo cpu=$(lscpu 2>/dev/null | grep 'Model name' | sed 's/.*: *//'); "
            + "echo cores=$(nproc 2>/dev/null); "
            + "else echo cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null); "
            + "echo cores=$(sysctl -n hw.ncpu 2>/dev/null); fi",
        // CPU percent — real 1s sample on Linux, top fallback on macOS
        "if [ -f /proc/stat ]; then "
            + "c1=$(awk '/^cpu /{s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat); "
            + "u1=$(awk '/^cpu /{print $2+$3+$4+$7+$8+$9+$10+$11}' /proc/stat); "
            + "sleep 1; "
            + "c2=$(awk '/^cpu /{s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat); "
            + "u2=$(awk '/^cpu /{print $2+$3+$4+$7+$8+$9+$10+$11}' /proc/stat); "
            + "echo cpu_percent=$(awk -v a=\"$c1\" -v b=\"$u1\" -v c=\"$c2\" -v d=\"$u2\" "
            + "'BEGIN{if ((c-a)>0) printf \"%.0f\", (d-b)*100/(c-a); else printf \"0\"}'); "
            + "elif command -v top >/dev/null 2>&1; then "
            + "echo cpu_percent=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/{gsub(\"%\",\"\",$7); print 100-$7}'); "
            + "else echo cpu_percent=$(sysctl -n vm.loadavg 2>/dev/null | awk '{printf \"%.0f\", $2*100}'); fi",
        // Memory — bytes with Linux free / macOS sysctl + vm_stat fallback
        "if command -v free >/dev/null 2>&1; then "
            + "echo mem=$(free -h 2>/dev/null | awk '/Mem:/{print $3\"/\"$2}'); "
            + "echo mem_used_bytes=$(free -b 2>/dev/null | awk '/^Mem:/{if ($7!=\"\") print $2-$7; else print $3}'); "
            + "echo mem_total_bytes=$(free -b 2>/dev/null | awk '/^Mem:/{print $2}'); "
            + "echo swap_used_bytes=$(free -b 2>/dev/null | awk '/^Swap:/{print $3}'); "
            + "echo swap_total_bytes=$(free -b 2>/dev/null | awk '/^Swap:/{print $2}'); "
            + "else "
            + "t=$(sysctl -n hw.memsize 2>/dev/null); "
            + "p=$(vm_stat 2>/dev/null | awk '/page size of/{print $8}'); "
            + "if [ -n \"$t\" ] && [ -n \"$p\" ]; then "
            + "f=$(vm_stat 2>/dev/null | awk '/Pages free/{print $3}' | tr -d '.'); "
            + "i=$(vm_stat 2>/dev/null | awk '/Pages inactive/{print $3}' | tr -d '.'); "
            + "echo mem_total_bytes=$t; "
            + "echo mem_used_bytes=$((t-(f+i)*p)); "
            + "else echo mem=$(($(sysctl -n hw.memsize 2>/dev/null)/1024/1024))MB; fi; "
            + "s=$(sysctl -n vm.swapusage 2>/dev/null); "
            + "if [ -n \"$s\" ]; then "
            + "st=$(echo \"$s\" | sed 's/.*total = \\([0-9.]*\\)M.*/\\1/'); "
            + "su=$(echo \"$s\" | sed 's/.*used = \\([0-9.]*\\)M.*/\\1/'); "
            + "echo swap_total_bytes=$(awk -v t=\"$st\" 'BEGIN{printf \"%d\", t*1048576}'); "
            + "echo swap_used_bytes=$(awk -v u=\"$su\" 'BEGIN{printf \"%d\", u*1048576}'); "
            + "fi; fi",
        // Disk — bytes (df -kP works on both Linux and macOS)
        "df -kP / 2>/dev/null | tail -1 | awk '{print \"disk_used_bytes=\" $3*1024; print \"disk_total_bytes=\" $2*1024}'",
        // Disk (human-readable, for the sidebar)
        "echo disk=$(df -h / 2>/dev/null | tail -1 | awk '{print $3\"/\"$2}')",
        // Load
        "if [ -f /proc/loadavg ]; then "
            + "echo load=$(cat /proc/loadavg | awk '{print $1, $2, $3}'); "
            + "else echo load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'); fi",
        // IP
        "echo ip=$(hostname -I 2>/dev/null | awk '{print $1}')",
        // CPU temperature (first Linux thermal zone)
        "if [ -f /sys/class/thermal/thermal_zone0/temp ]; then "
            + "echo cpu_temp_c=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf \"%.0f\", $1/1000}'); fi",
        // Disk IO — cumulative bytes; the monitor turns deltas into rates
        "if [ -f /proc/diskstats ]; then "
            + "awk '$3 !~ /^(loop|ram|sr|fd|zram)/ {r+=$6; w+=$10} "
            + "END {print \"disk_read_bytes=\" r*512; print \"disk_write_bytes=\" w*512}' /proc/diskstats; fi",
        // Top processes by CPU ("12.3|bash;")
        "if command -v ps >/dev/null 2>&1; then "
            + "echo top_procs=$(ps -eo pcpu,comm --sort=-pcpu 2>/dev/null "
            + "| awk 'NR>1 && NR<=4 {printf \"%s|%s;\", $1, $2}'); fi",
        // Listening TCP ports (top 8)
        "if command -v ss >/dev/null 2>&1; then "
            + "echo listen_ports=$(ss -tlnH 2>/dev/null | awk '{split($4,a,\":\"); print a[length(a)]}' "
            + "| sort -n | uniq | head -8 | tr '\\n' ','); "
            + "elif command -v netstat >/dev/null 2>&1; then "
            + "echo listen_ports=$(netstat -tln 2>/dev/null | awk 'NR>2 {split($4,a,\":\"); print a[length(a)]}' "
            + "| sort -n | uniq | head -8 | tr '\\n' ','); fi",
        // Network — cumulative bytes; the monitor turns deltas into rates
        "if [ -f /proc/net/dev ]; then "
            + "awk 'NR>2 {gsub(\":\",\"\",$1); if ($1!=\"lo\") {rx+=$2; tx+=$10}} "
            + "END {print \"net_rx_bytes=\" rx; print \"net_tx_bytes=\" tx}' /proc/net/dev; "
            + "else "
            + "netstat -ibn 2>/dev/null | awk '/Link#/ && $1!=\"lo0\" {rx+=$7; tx+=$10} "
            + "END {print \"net_rx_bytes=\" rx; print \"net_tx_bytes=\" tx}'; fi",
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

    private nonisolated(unsafe) static let keyMap: [String: WritableKeyPath<ServerInfo, String?>] = [
        "hostname": \.hostname,
        "os": \.os,
        "kernel": \.kernel,
        "arch": \.architecture,
        "cpu": \.cpuModel,
        "cores": \.cpuCores,
        "mem": \.memoryUsed,
        "disk": \.diskUsed,
        "load": \.loadAverage,
        "ip": \.serverIP,
        "shell": \.shell,
        "top_procs": \.topProcesses,
        "listen_ports": \.listenPorts,
    ]

    private nonisolated(unsafe) static let numericKeyMap: [String: WritableKeyPath<ServerInfo, Double?>] = [
        "cpu_percent": \.cpuUsagePercent,
        "cpu_temp_c": \.cpuTempCelsius,
    ]

    private nonisolated(unsafe) static let byteKeyMap: [String: WritableKeyPath<ServerInfo, UInt64?>] = [
        "mem_used_bytes": \.memUsedBytes,
        "mem_total_bytes": \.memTotalBytes,
        "disk_used_bytes": \.diskUsedBytes,
        "disk_total_bytes": \.diskTotalBytes,
        "swap_used_bytes": \.swapUsedBytes,
        "swap_total_bytes": \.swapTotalBytes,
        "net_rx_bytes": \.networkRXBytes,
        "net_tx_bytes": \.networkTXBytes,
        "disk_read_bytes": \.diskReadBytes,
        "disk_write_bytes": \.diskWriteBytes,
        "uptime_seconds": \.uptimeSeconds,
    ]

    static func parseOutput(_ output: String) -> ServerInfo {
        var info = ServerInfo()
        for line in output.components(separatedBy: "\n") {
            guard let (key, value) = parseLine(line) else { continue }
            if let keyPath = numericKeyMap[key], let number = Double(value) {
                info[keyPath: keyPath] = number
                continue
            }
            if let keyPath = byteKeyMap[key], let bytes = UInt64(value) {
                info[keyPath: keyPath] = bytes
                continue
            }
            if let keyPath = keyMap[key] {
                info[keyPath: keyPath] = value
            }
        }
        return info
    }

    private static func parseLine(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let eqIndex = trimmed.firstIndex(of: "=") else { return nil }
        let key = String(trimmed[trimmed.startIndex ..< eqIndex])
        let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return (key, value)
    }
}
