//  BuiltinCommandIndex.swift
//  Bonk
//
//  Curated high-frequency builtin commands with summaries and priorities.
//

import Foundation

/// A static command descriptor with documentation and usage frequency.
struct CommandEntry: Sendable, Equatable {
    let name: String
    let summary: String
    let frequency: Int

    init(_ name: String, _ summary: String, _ frequency: Int = 80) {
        self.name = name
        self.summary = summary
        self.frequency = frequency
    }
}

/// High-performance memory index of curated developer and system commands.
final class BuiltinCommandIndex: CommandIndex, @unchecked Sendable {
    static let shared = BuiltinCommandIndex()

    private let entries: [CommandEntry]

    init(entries: [CommandEntry] = BuiltinCommandIndex.defaultEntries) {
        self.entries = entries
    }

    /// Match prefix against builtin commands, returning top ranked InlineCandidates.
    func matches(prefix: String, limit: Int = 5) -> [InlineCandidate] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        var matching: [(entry: CommandEntry, isExact: Bool)] = []
        for entry in entries {
            let lower = entry.name.lowercased()
            if lower.hasPrefix(trimmed) && lower.count >= trimmed.count {
                matching.append((entry, lower == trimmed))
            }
        }

        // Sort by frequency descending; exact prefix priority
        matching.sort { a, b in
            if a.isExact != b.isExact { return a.isExact }
            return a.entry.frequency > b.entry.frequency
        }

        return matching.prefix(limit).map { item in
            let suffix: String
            if item.entry.name.count > trimmed.count {
                suffix = String(item.entry.name.dropFirst(trimmed.count))
            } else {
                suffix = ""
            }
            let display = suffix
            let sug = Suggestion(text: suffix, displayText: display, fullText: item.entry.name)
            let baseScore = 70.0 + (Double(item.entry.frequency) / 100.0) * 8.0 + (item.isExact ? 2.0 : 0.0)
            return InlineCandidate(
                source: .vocabulary,
                authority: .deterministic,
                suggestion: sug,
                rawScore: baseScore,
                isExactPrefixMatch: item.isExact,
                summary: item.entry.summary
            )
        }
    }

    /// Set of all builtin command names for quick membership checks.
    var allNames: Set<String> {
        Set(entries.map(\.name))
    }

    /// Curated catalog of developer, system, network, container, and cloud CLI commands.
    static let defaultEntries: [CommandEntry] = [
        // MARK: - D Commands
        CommandEntry("docker", "Container application platform", 99),
        CommandEntry("docker-compose", "Multi-container Docker applications", 96),
        CommandEntry("df", "Display free disk space", 95),
        CommandEntry("du", "Display directory space usage", 93),
        CommandEntry("diff", "Compare files line by line", 92),
        CommandEntry("dig", "DNS lookup utility", 91),
        CommandEntry("dirname", "Strip last component from file path", 84),
        CommandEntry("date", "Display or set system date and time", 88),
        CommandEntry("dd", "Convert and copy raw file data", 82),
        CommandEntry("dmesg", "Print kernel ring buffer messages", 85),
        CommandEntry("dnf", "Package manager for RPM distributions", 89),
        CommandEntry("dpkg", "Debian package manager", 86),
        CommandEntry("defaults", "macOS user defaults system configuration", 84),
        CommandEntry("diskutil", "macOS disk management utility", 85),
        CommandEntry("dotnet", ".NET command-line interface", 86),
        CommandEntry("deno", "Secure TypeScript and JavaScript runtime", 87),

        // MARK: - G Commands
        CommandEntry("git", "Distributed version control system", 100),
        CommandEntry("gh", "GitHub CLI tool", 94),
        CommandEntry("grep", "Search file pattern matching regular expressions", 97),
        CommandEntry("gzip", "Compress or decompress files (.gz)", 87),
        CommandEntry("gunzip", "Decompress gzip files", 85),
        CommandEntry("go", "Go programming language toolchain", 93),
        CommandEntry("g++", "GNU C++ compiler", 86),
        CommandEntry("gcc", "GNU C compiler", 87),
        CommandEntry("gradle", "Build automation tool for Java/Kotlin", 85),
        CommandEntry("gcloud", "Google Cloud SDK command-line tool", 88),
        CommandEntry("gpg", "OpenPGP encryption and signing tool", 86),

        // MARK: - C Commands
        CommandEntry("cd", "Change working directory", 100),
        CommandEntry("cat", "Concatenate and print file contents", 98),
        CommandEntry("curl", "Transfer data with URL syntax", 98),
        CommandEntry("cp", "Copy files and directories", 96),
        CommandEntry("chmod", "Change file access permissions", 94),
        CommandEntry("chown", "Change file owner and group", 92),
        CommandEntry("cargo", "Rust package manager and build tool", 94),
        CommandEntry("clear", "Clear the terminal screen", 93),
        CommandEntry("crontab", "Schedule periodic background tasks", 85),
        CommandEntry("cut", "Remove sections from lines of files", 86),
        CommandEntry("code", "Visual Studio Code editor", 89),
        CommandEntry("cmake", "Cross-platform build system generator", 88),
        CommandEntry("clang", "C and Objective-C LLVM compiler", 85),
        CommandEntry("composer", "PHP dependency manager", 82),

        // MARK: - L Commands
        CommandEntry("ls", "List directory contents", 100),
        CommandEntry("less", "View file contents with backwards pagination", 95),
        CommandEntry("lsof", "List open files and network connections", 93),
        CommandEntry("ln", "Make links between files (symbolic or hard)", 89),
        CommandEntry("loginctl", "Control systemd login manager", 80),
        CommandEntry("launchctl", "macOS service management framework", 85),
        CommandEntry("locate", "Find files by name quickly via database", 82),
        CommandEntry("lsblk", "List block storage devices", 87),

        // MARK: - S Commands
        CommandEntry("ssh", "OpenSSH remote login client", 99),
        CommandEntry("sudo", "Execute command as superuser", 99),
        CommandEntry("systemctl", "Control systemd system and service manager", 96),
        CommandEntry("scp", "Secure copy file over SSH", 92),
        CommandEntry("sftp", "Secure File Transfer Protocol client", 90),
        CommandEntry("sed", "Stream editor for filtering and transforming text", 92),
        CommandEntry("sort", "Sort lines of text files", 89),
        CommandEntry("ss", "Dump socket statistics (modern netstat)", 91),
        CommandEntry("screen", "Terminal multiplexer with session detachment", 82),
        CommandEntry("sh", "Standard command interpreter", 88),
        CommandEntry("source", "Execute commands from file in current shell", 88),
        CommandEntry("swift", "Swift compiler and interactive REPL", 85),
        CommandEntry("strace", "Trace system calls and signals", 84),

        // MARK: - K Commands
        CommandEntry("kubectl", "Kubernetes cluster control CLI", 97),
        CommandEntry("kill", "Send signal to terminate processes", 93),
        CommandEntry("killall", "Kill processes by name", 90),
        CommandEntry("k9s", "Terminal-based Kubernetes UI", 88),

        // MARK: - N Commands
        CommandEntry("npm", "Node.js package manager", 96),
        CommandEntry("npx", "Execute npm package binaries directly", 93),
        CommandEntry("node", "JavaScript runtime environment", 93),
        CommandEntry("nginx", "High performance web server and reverse proxy", 92),
        CommandEntry("netstat", "Network statistics and routing tables", 89),
        CommandEntry("nc", "Netcat arbitrary TCP and UDP connections", 88),
        CommandEntry("nano", "Simple terminal text editor", 86),
        CommandEntry("nohup", "Run command immune to hangups", 85),

        // MARK: - P Commands
        CommandEntry("pnpm", "Fast disk space efficient package manager", 95),
        CommandEntry("ps", "Report current process snapshot", 96),
        CommandEntry("pwd", "Print working directory", 97),
        CommandEntry("python3", "Python 3 programming language interpreter", 95),
        CommandEntry("python", "Python programming language interpreter", 93),
        CommandEntry("pip", "Python package installer", 92),
        CommandEntry("pip3", "Python 3 package installer", 92),
        CommandEntry("ping", "Send ICMP ECHO_REQUEST to network hosts", 93),
        CommandEntry("pbcopy", "macOS copy input to clipboard", 90),
        CommandEntry("pbpaste", "macOS paste from clipboard", 89),
        CommandEntry("podman", "Daemonless container engine", 87),

        // MARK: - T Commands
        CommandEntry("tar", "Tape archive utility", 94),
        CommandEntry("tail", "Output last part of files (e.g. tail -f)", 95),
        CommandEntry("top", "Display dynamic real-time Linux tasks", 92),
        CommandEntry("htop", "Interactive process viewer", 93),
        CommandEntry("touch", "Change file timestamps or create empty file", 93),
        CommandEntry("tmux", "Terminal multiplexer with panes and windows", 93),
        CommandEntry("terraform", "Infrastructure as Code tool by HashiCorp", 91),
        CommandEntry("tree", "Display directory hierarchy as a tree", 88),
        CommandEntry("tldr", "Collaborative simplified man pages", 86),
        CommandEntry("traceroute", "Trace route to network host", 87),

        // MARK: - M / U / V / W / Z Commands
        CommandEntry("make", "Build automation utility from Makefiles", 91),
        CommandEntry("mkdir", "Create new directories", 96),
        CommandEntry("mv", "Move or rename files", 96),
        CommandEntry("man", "Interface to system reference manuals", 88),
        CommandEntry("uname", "Print operating system name and architecture", 89),
        CommandEntry("uptime", "Show how long the system has been running", 87),
        CommandEntry("uniq", "Report or omit repeated lines in text", 85),
        CommandEntry("unzip", "Extract compressed files in a ZIP archive", 89),
        CommandEntry("ufw", "Uncomplicated Firewall manager", 88),
        CommandEntry("vim", "Vi IMproved text editor", 95),
        CommandEntry("vi", "Screen-oriented text editor", 89),
        CommandEntry("valgrind", "Memory debugging and profiling tool", 82),
        CommandEntry("wget", "Non-interactive network downloader", 90),
        CommandEntry("wc", "Print newline, word, and byte counts", 89),
        CommandEntry("which", "Locate a command executable in PATH", 92),
        CommandEntry("whoami", "Print current effective user name", 90),
        CommandEntry("watch", "Execute a program periodically and show output", 88),
        CommandEntry("xargs", "Build and execute command lines from standard input", 90),
        CommandEntry("xcodebuild", "Build Xcode projects and workspaces", 88),
        CommandEntry("yum", "Package manager for RedHat/CentOS", 87),
        CommandEntry("yarn", "Fast reliable package manager for JavaScript", 91),
        CommandEntry("zsh", "Z shell command interpreter", 90),
        CommandEntry("zip", "Package and compress files (.zip)", 89),
        CommandEntry("jq", "Command-line JSON processor", 94),
        CommandEntry("yq", "Command-line YAML/XML processor", 88),
        CommandEntry("rg", "Ripgrep - blazing fast recursive search", 96),
        CommandEntry("fd", "Simple, fast and user-friendly alternative to find", 91)
    ]
}
