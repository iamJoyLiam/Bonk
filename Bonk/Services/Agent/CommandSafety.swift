import Foundation

/// Classifies shell commands by risk level for Agent mode.
/// Handles pipes, chains (&&, ||, ;), and sudo subcommands.
enum CommandSafety {
    case safe // 直接执行
    case moderate // 显示警告，用户可一键确认
    case dangerous // 必须手动确认
    case blocked // 永远不允许

    static func classify(_ command: String) -> CommandSafety {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .blocked }

        let segments = splitByChainOperators(trimmed)
        var highestRisk: CommandSafety = .safe

        for segment in segments {
            let risk = classifySingleCommand(segment)
            if risk.priority > highestRisk.priority {
                highestRisk = risk
            }
            if risk == .blocked { return .blocked }
        }

        return highestRisk
    }

    // MARK: - Single Command

    private static func classifySingleCommand(_ command: String) -> CommandSafety {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return .blocked }

        // Blocked
        if isBlocked(trimmed) { return .blocked }

        // sudo → delegate to subcommand
        if cmd == "sudo" { return classifySudo(parts) }

        // Dangerous
        if isDangerous(cmd) { return .dangerous }

        // Moderate
        if isModerate(cmd, trimmed) { return .moderate }

        // -rf / -fr / -r -f anywhere → dangerous
        if hasRecursiveForceFlag(trimmed) { return .dangerous }

        // Redirects (not to /dev/null) → moderate
        if trimmed.contains(" >> ") || trimmed.contains(" > "),
           !trimmed.contains("> /dev/null")
        {
            return .moderate
        }

        return .safe
    }

    // MARK: - Blocked

    private static func isBlocked(_ command: String) -> Bool {
        let blocked = [
            "rm -rf /", "rm -rf /*", "rm -rf ~",
            "mkfs", "dd if=/dev/zero", "dd if=/dev/random",
            ":(){ :|:& };:",
            "chmod -R 777 /", "chmod 777 /",
            "> /dev/sda", "> /dev/nvme",
            "wget -O- | sh", "curl | sh", "curl | bash",
            "nc -e", "ncat -e",
        ]
        let lower = command.lowercased()
        if blocked.contains(where: { lower.contains($0) }) { return true }

        // Block writes to shell rc files
        let shellRCFiles = [".bashrc", ".zshrc", ".profile", ".bash_profile"]
        for shellRC in shellRCFiles {
            if command.contains(shellRC), command.contains(">>") || command.contains(">") {
                return true
            }
        }
        return false
    }

    // MARK: - Dangerous

    private static let dangerousCommands: Set<String> = [
        "rm", "rmdir", "kill", "killall", "pkill",
        "shutdown", "reboot", "halt", "poweroff",
        "systemctl", "service", "launchctl",
        "iptables", "ufw", "firewall-cmd",
        "passwd", "userdel", "groupdel", "usermod",
        "fdisk", "parted", "mount", "umount",
        "crontab", "at", "mkswap", "swapon", "swapoff",
        "lvm", "vgcreate", "lvcreate",
    ]

    private static func isDangerous(_ cmd: String) -> Bool {
        dangerousCommands.contains(cmd)
    }

    /// Detect -rf, -fr, -r -f, -f -r patterns (recursive + force).
    private static func hasRecursiveForceFlag(_ command: String) -> Bool {
        let lower = command.lowercased()
        // Combined flags: -rf, -fr, or longer like -rfv
        let combinedPattern = #"(^|\s)-[a-z]*r[a-z]*f[a-z]*($|\s)|(^|\s)-[a-z]*f[a-z]*r[a-z]*($|\s)"#
        if lower.range(of: combinedPattern, options: .regularExpression) != nil { return true }
        // Separated flags: -r ... -f or -f ... -r
        if lower.contains(" -r ") && lower.contains(" -f ") { return true }
        if (lower.hasSuffix(" -r") || lower.contains(" -r ")) &&
            (lower.hasSuffix(" -f") || lower.contains(" -f ")) { return true }
        return false
    }

    // MARK: - Moderate

    private static let moderateCommands: Set<String> = [
        "mv", "cp", "mkdir", "touch", "ln", "install",
        "chown", "chmod", "chgrp", "setfacl",
        "apt", "apt-get", "yum", "dnf", "pacman", "brew", "zypper",
        "pip", "pip3", "pipx", "npm", "yarn", "pnpm", "cargo", "gem",
        "docker", "podman", "kubectl", "helm",
        "mysql", "psql", "redis-cli", "mongosh", "sqlite3",
        "tee", "dd", "rsync", "scp", "sftp",
        "tar", "zip", "unzip", "gzip", "gunzip",
        "make", "cmake", "ninja",
    ]

    /// Commands that are moderate only with specific flags
    private static let moderatePrefixes = ["sed -i", "awk -i", "git push", "git reset", "git clean", "git checkout"]

    private static func isModerate(_ cmd: String, _ full: String) -> Bool {
        if moderateCommands.contains(cmd) { return true }
        return moderatePrefixes.contains(where: { full.hasPrefix($0) })
    }

    // MARK: - Sudo

    private static func classifySudo(_ parts: [String]) -> CommandSafety {
        guard parts.count > 1 else { return .dangerous }
        let sub = parts[1]
        let rest = parts.dropFirst().joined(separator: " ")

        if isBlocked(rest) { return .blocked }
        if ["apt", "apt-get", "yum", "dnf", "pacman", "brew", "zypper", "pip", "npm"].contains(sub) { return .moderate }
        return .dangerous
    }

    // MARK: - Chain Splitting

    private static func splitByChainOperators(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var cursor = command.startIndex

        while cursor < command.endIndex {
            let char = command[cursor]
            let next = command.index(after: cursor)

            if char == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                current.append(char)
            } else if char == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                current.append(char)
            } else if !inSingleQuote, !inDoubleQuote {
                if char == "&", next < command.endIndex, command[next] == "&" {
                    appendSegment(&current, to: &segments)
                    cursor = command.index(after: next)
                    continue
                } else if char == "|", next < command.endIndex, command[next] == "|" {
                    appendSegment(&current, to: &segments)
                    cursor = command.index(after: next)
                    continue
                } else if char == "|" {
                    // Pipe — split and classify each segment
                    appendSegment(&current, to: &segments)
                    cursor = next
                    continue
                } else if char == ";" {
                    appendSegment(&current, to: &segments)
                    cursor = next
                    continue
                } else {
                    current.append(char)
                }
            } else {
                current.append(char)
            }
            cursor = next
        }

        appendSegment(&current, to: &segments)
        return segments
    }

    private static func appendSegment(_ current: inout String, to segments: inout [String]) {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { segments.append(trimmed) }
        current = ""
    }

    // MARK: - Priority

    private static let priorities: [CommandSafety: Int] = [
        .safe: 0, .moderate: 1, .dangerous: 2, .blocked: 3,
    ]

    private var priority: Int {
        Self.priorities[self] ?? 0
    }

    var description: String {
        switch self {
        case .safe: "Safe"
        case .moderate: "Moderate"
        case .dangerous: "Dangerous"
        case .blocked: "Blocked"
        }
    }

    var icon: String {
        switch self {
        case .safe: "checkmark.shield"
        case .moderate: "exclamationmark.triangle"
        case .dangerous: "exclamationmark.octagon"
        case .blocked: "xmark.shield"
        }
    }
}
