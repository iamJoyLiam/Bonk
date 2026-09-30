import Foundation

/// Explicit execution permission tiers (L0..L4).
enum CommandSafetyLevel: Int, Comparable, Sendable {
    case l0Explanation = 0     // Read-only / Pure explanation (no command execution)
    case l1SafeInspection = 1  // Safe read-only inspection (ls, ps, pwd, git status, docker ps)
    case l2StateMutation = 2   // State modification (mkdir, touch, cp, git commit, npm install)
    case l3HighRisk = 3        // Destructive / dangerous (rm, kill, reboot, docker rm)
    case l4Critical = 4        // Blocked / privilege escalation (sudo, mkfs, destructive root)

    static func < (lhs: CommandSafetyLevel, rhs: CommandSafetyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Classifies shell commands by risk level for Agent mode.
/// Handles pipes, chains (&&, ||, ;), and sudo subcommands.
enum CommandSafety {
    case safe //  
    case moderate //  
    case dangerous //  
    case blocked //  

    var level: CommandSafetyLevel {
        switch self {
        case .safe: return .l1SafeInspection
        case .moderate: return .l2StateMutation
        case .dangerous: return .l3HighRisk
        case .blocked: return .l4Critical
        }
    }

    static func classifyLevel(_ command: String) -> CommandSafetyLevel {
        classify(command).level
    }

    static func classify(_ command: String) -> CommandSafety {
        // Newlines included: the shell this string is handed to treats a
        // leading or trailing newline as a separator, so trimming it away here
        // would hide a second command rather than remove one.
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .blocked }
        if isBlocked(trimmed) { return .blocked }

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

    private static func classifySingleCommand(_ command: String, depth: Int = 0) -> CommandSafety {
        // Newlines included for the same reason as in `classify`: a segment that
        // still carries one misses the exact-match sets and reads as safe.
        var trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .blocked }
        if isBlocked(trimmed) { return .blocked }

        // Command substitution / backticks: attacker-controlled inner content
        // must be classified too (e.g. `echo $(rm -rf ~)`). Never lowers risk.
        let substitutionRisk = classifySubstitutions(trimmed)

        // A single layer of subshell parens does not change what runs:
        // `(rm -rf /)` is the same payload as `rm -rf /`.
        trimmed = stripSubshellParens(trimmed)

        let parts = trimmed.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return .blocked }

        let base: CommandSafety = {
            // sudo → delegate to subcommand (with flag skipping: -u/-g/-p/-r take values)
            if cmd == "sudo" { return classifySudo(parts) }

            // Shell / script interpreters execute code: `curl x | sh`,
            // `bash -c '...'`, `python3 script.py` all need a decision, never silent allow.
            if shellInterpreters.contains(cmd) { return classifyInterpreter(parts) }

            // Wrapper verbs must not hide the real command:
            // `env FOO=1 rm -rf /x`, `xargs rm`, `find . -exec rm {} \;`, `su -c '...'`.
            if cmd == "find" { return classifyFind(parts) }
            if cmd == "xargs" { return classifyXargs(parts) }
            if cmd == "su" { return classifySu(parts) }
            if wrapperCommands.contains(cmd) {
                guard depth < maxUnwrapDepth else { return .moderate }
                let rest = unwrapPlainWrapper(cmd: cmd, parts: parts)
                guard !rest.isEmpty else { return .moderate }
                // Floor: a wrapper that survived parsing still deserves confirmation.
                return maxRisk(classifySingleCommand(rest, depth: depth + 1), .moderate)
            }

            // Read-only listings are safe even for normally risky tools
            // (e.g. `fdisk -l`, `parted -l`, bare `mount`, `docker ps`).
            if isReadOnlyListing(cmd, trimmed) { return .safe }

            // Dangerous
            if isDangerous(cmd) { return .dangerous }

            // Moderate
            if isModerate(cmd, trimmed) { return .moderate }

            // -rf / -fr / -r -f anywhere → dangerous
            if hasRecursiveForceFlag(trimmed) { return .dangerous }

            // File redirects (spaced or not, except to /dev/null) → moderate;
            // redirects into shell rc / cron / sudoers / ssh trust files → blocked.
            if let redirectRisk = fileRedirectRisk(trimmed) { return redirectRisk }

            return .safe
        }()

        return maxRisk(base, substitutionRisk ?? .safe)
    }

    private static let maxUnwrapDepth = 8

    private static func maxRisk(_ a: CommandSafety, _ b: CommandSafety) -> CommandSafety {
        a.priority >= b.priority ? a : b
    }

    // MARK: - Blocked

    /// Read-only invocations of normally risky tools. They list or inspect
    /// state without modifying anything, so they should run without prompts.
    private static func isReadOnlyListing(_ cmd: String, _ full: String) -> Bool {
        let lower = full.lowercased()
        switch cmd {
        case "fdisk", "parted", "sfdisk":
            return lower.contains(" -l") || lower.contains("--list")
                || lower.contains("--print")
        case "mount":
            return !lower.contains(" -") // bare `mount` just lists mounts
        case "blkid", "findmnt", "lsblk":
            return true
        case "docker", "podman":
            let safeSubcommands = ["ps", "images", "version", "info", "stats", "top", "port", "container ls", "image ls"]
            return safeSubcommands.contains { lower.hasPrefix("\(cmd) \($0)") || lower == "\(cmd) \($0)" }
        case "kubectl":
            let safeSubcommands = ["get", "describe", "logs", "version", "cluster-info", "top"]
            return safeSubcommands.contains { lower.hasPrefix("\(cmd) \($0)") || lower == "\(cmd) \($0)" }
        case "git":
            let safeSubcommands = ["status", "log", "diff", "branch", "show", "tag"]
            return safeSubcommands.contains { lower.hasPrefix("\(cmd) \($0)") || lower == "\(cmd) \($0)" }
        default:
            return false
        }
    }

    private static func isBlocked(_ command: String) -> Bool {
        let blocked = [
            "rm -rf /", "rm -rf /*", "rm -rf ~",
            "mkfs", "dd if=/dev/zero", "dd if=/dev/random",
            ":(){ :|:& };:",
            "chmod -r 777 /", "chmod 777 /",
            "> /dev/sda", "> /dev/nvme",
            "wget -o- | sh", "curl | sh", "curl | bash",
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
        let hasRecursive = lower.hasSuffix(" -r") || lower.contains(" -r ")
        let hasForce = lower.hasSuffix(" -f") || lower.contains(" -f ")
        return hasRecursive && hasForce
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
        // Skip sudo options: -u/--user, -g/--group, -p/--prompt, -r/--role,
        // -C/--close-from consume the following token; other -flags are standalone.
        let sudoValueFlags: Set<String> = ["-u", "--user", "-g", "--group", "-p", "--prompt", "-r", "--role", "-C", "--close-from"]
        var idx = 1
        while idx < parts.count {
            let token = parts[idx]
            if sudoValueFlags.contains(token) {
                idx += 2
                continue
            }
            if token.hasPrefix("-"), token.count > 1 { idx += 1; continue }
            break
        }
        guard idx < parts.count else { return .dangerous }
        let sub = parts[idx]
        let rest = parts[idx...].joined(separator: " ")

        if isBlocked(rest) { return .blocked }
        if ["apt", "apt-get", "yum", "dnf", "pacman", "brew", "zypper", "pip", "npm"].contains(sub) { return .moderate }
        return .dangerous
    }

    // MARK: - Shell Interpreters

    /// Verbs that execute code rather than perform a fixed operation.
    /// A bare interpreter (`sh` as a pipe target, `python3 script.py`)
    /// runs arbitrary input → dangerous. `-c`/`-e` payloads are classified
    /// recursively so `sh -c 'rm -rf /'` is blocked while version/help
    /// probes stay silent.
    private static let shellInterpreters: Set<String> = [
        "sh", "bash", "dash", "zsh", "fish", "ksh",
        "python", "python3", "perl", "ruby", "node", "php", "lua",
    ]

    private static func classifyInterpreter(_ parts: [String]) -> CommandSafety {
        guard parts.count > 1 else { return .dangerous }
        let args = Array(parts.dropFirst())
        // Read-only probes stay quiet.
        if args.allSatisfy({ $0 == "--version" || $0 == "-V" || $0 == "-v" || $0 == "-h" || $0 == "--help" }) {
            return .safe
        }
        // -c/--command/-e payload: classify what would actually run.
        if let flagIdx = args.firstIndex(where: { $0 == "-c" || $0 == "--command" || $0 == "-e" }) {
            let payload = args.dropFirst(flagIdx + 1).joined(separator: " ")
            guard !payload.isEmpty else { return .dangerous }
            return classify(payload)
        }
        return .dangerous
    }

    // MARK: - Wrapper Verbs

    /// Verbs that only wrap another command. Unwrap and classify the inner
    /// command so `env FOO=1 rm -rf /x` cannot hide behind `env`.
    private static let wrapperCommands: Set<String> = [
        "env", "nohup", "time", "nice", "stdbuf", "watch", "timeout", "command",
    ]

    /// Strip the wrapper verb plus its options, returning the inner command.
    /// Unknown `-flags` stop unwrapping (the caller floors the result at
    /// moderate) rather than being silently skipped with their values.
    private static func unwrapPlainWrapper(cmd: String, parts: [String]) -> String {
        var tokens = Array(parts.dropFirst())
        // env VAR=assignments never contribute risk by themselves.
        if cmd == "env" {
            while let first = tokens.first, isEnvAssignment(first) { tokens.removeFirst() }
        }
        let valueFlags: Set<String>
        let standaloneOK: Bool
        switch cmd {
        case "env":
            valueFlags = ["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]
            standaloneOK = true // -i, -0, ...
        case "timeout":
            valueFlags = ["-s", "--signal", "-k", "--kill-after"]
            standaloneOK = true // --preserve-status, -v, ...
        case "watch":
            valueFlags = ["-n", "--interval"]
            standaloneOK = true // -d, -t, -b, -e, -g, -x, ...
        case "nice":
            valueFlags = ["-n", "--adjustment"]
            standaloneOK = true
        case "stdbuf":
            valueFlags = ["-i", "--input", "-o", "--output", "-e", "--error"]
            standaloneOK = false // inline forms like -o0 handled below
        case "nohup", "time", "command":
            valueFlags = []
            standaloneOK = true
        default:
            valueFlags = []
            standaloneOK = false
        }
        while let first = tokens.first, first.hasPrefix("-"), first.count > 1 {
            let name = first.split(separator: "=", maxSplits: 1).map(String.init)[0]
            if valueFlags.contains(name) {
                tokens.removeFirst()
                // Inline value (--signal=TERM, -o0): nothing more to consume.
                if !first.contains("="), first == name, !tokens.isEmpty { tokens.removeFirst() }
                continue
            }
            if cmd == "stdbuf", inlineValueFlagPrefix(first) != nil {
                tokens.removeFirst()
                continue
            }
            if standaloneOK { tokens.removeFirst(); continue }
            break // unknown flag: stop, caller floors at moderate
        }
        if cmd == "timeout", let first = tokens.first, isDurationToken(first) {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ")
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "=") else { return false }
        let name = token[..<eq]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func inlineValueFlagPrefix(_ token: String) -> String? {
        for prefix in ["-i", "-o", "-e"] where token.hasPrefix(prefix) && token != prefix {
            return prefix
        }
        return nil
    }

    private static func isDurationToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let core = token.last.map { "smhd".contains($0) } == true ? token.dropLast() : token[...]
        guard !core.isEmpty else { return false }
        var dotSeen = false
        return core.allSatisfy {
            if $0 == ".", !dotSeen { dotSeen = true; return true }
            return $0.isNumber
        }
    }

    // MARK: - xargs / find / su

    private static func classifyXargs(_ parts: [String]) -> CommandSafety {
        let valueFlags: Set<String> = ["-n", "--max-args", "-I", "--replace", "-d", "--delimiter", "-P", "--max-procs", "-a", "--arg-file", "-s", "--max-chars", "-E", "--eof"]
        var tokens = Array(parts.dropFirst())
        while let first = tokens.first, first.hasPrefix("-"), first.count > 1 {
            let name = first.split(separator: "=", maxSplits: 1).map(String.init)[0]
            tokens.removeFirst()
            if valueFlags.contains(name), !first.contains("="), !tokens.isEmpty { tokens.removeFirst() }
        }
        // Floor at moderate: xargs builds argv from stdin we cannot inspect, so
        // even a safe-looking inner command executes dynamic arguments.
        guard !tokens.isEmpty else { return .moderate }
        return maxRisk(classify(tokens.joined(separator: " ")), .moderate)
    }

    private static func classifyFind(_ parts: [String]) -> CommandSafety {
        let tokens = Array(parts.dropFirst())
        if tokens.contains("-delete") { return .dangerous }
        var worst: CommandSafety?
        var idx = tokens.startIndex
        while idx < tokens.endIndex {
            let token = tokens[idx]
            if ["-exec", "-execdir", "-ok", "-okdir"].contains(token) {
                var payload: [String] = []
                idx = tokens.index(after: idx)
                while idx < tokens.endIndex, tokens[idx] != ";", tokens[idx] != "+" {
                    payload.append(tokens[idx])
                    idx = tokens.index(after: idx)
                }
                let inner = payload.joined(separator: " ")
                let risk: CommandSafety = inner.isEmpty ? .moderate : classify(inner)
                worst = worst.map { maxRisk($0, risk) } ?? risk
            } else {
                idx = tokens.index(after: idx)
            }
        }
        // Plain `find` (no -exec/-delete) only reads the tree → safe.
        return worst ?? .safe
    }

    private static func classifySu(_ parts: [String]) -> CommandSafety {
        // Crossing a user boundary always needs confirmation; a blocked
        // payload inside -c still propagates as blocked.
        if let cIdx = parts.firstIndex(of: "-c") ?? parts.firstIndex(of: "--command") {
            let payload = parts.dropFirst(cIdx + 1).joined(separator: " ")
            guard !payload.isEmpty else { return .dangerous }
            return maxRisk(classify(payload), .dangerous)
        }
        return .dangerous
    }

    // MARK: - Command Substitution

    /// `$(...)` and backticks execute before the outer command does.
    /// Classify each inner payload (full pipeline: chains included) and
    /// return the worst risk found, or nil when there is none.
    /// Only single-quoted regions are skipped: `"$(...)"` still expands.
    private static func classifySubstitutions(_ command: String) -> CommandSafety? {
        var worst: CommandSafety?
        let chars = Array(command)
        var idx = 0
        var inSingleQuote = false
        while idx < chars.count {
            let char = chars[idx]
            if char == "'", !isEscaped(chars, idx) {
                inSingleQuote.toggle()
                idx += 1
                continue
            }
            if inSingleQuote {
                idx += 1
                continue
            }
            if char == "$", idx + 1 < chars.count, chars[idx + 1] == "(" {
                if let (inner, next) = extractBalanced(chars, from: idx + 2) {
                    worst = maxRisk(worst ?? .safe, classify(inner))
                    idx = next
                    continue
                }
                // Unbalanced `$(`: suspicious, floor at moderate.
                worst = maxRisk(worst ?? .safe, .moderate)
                idx += 1
                continue
            }
            if char == "`" {
                if let end = chars[(idx + 1)...].firstIndex(of: "`") {
                    worst = maxRisk(worst ?? .safe, classify(String(chars[(idx + 1)..<end])))
                    idx = end + 1
                    continue
                }
                idx += 1
                continue
            }
            idx += 1
        }
        return worst
    }

    private static func isEscaped(_ chars: [Character], _ idx: Int) -> Bool {
        var backslashes = 0
        var i = idx
        while i > 0 {
            i -= 1
            guard chars[i] == "\\" else { break }
            backslashes += 1
        }
        return backslashes % 2 == 1
    }

    /// Extract balanced `(...)` content starting at `from` (just past `$(`).
    /// Returns the inner text plus the index just past the closing paren.
    private static func extractBalanced(_ chars: [Character], from: Int) -> (String, Int)? {
        var depth = 1
        var idx = from
        var inSingleQuote = false
        while idx < chars.count {
            let char = chars[idx]
            if char == "'", !isEscaped(chars, idx) { inSingleQuote.toggle() }
            if !inSingleQuote {
                if char == "(" { depth += 1 }
                if char == ")" {
                    depth -= 1
                    if depth == 0 {
                        return (String(chars[from..<idx]), idx + 1)
                    }
                }
            }
            idx += 1
        }
        return nil
    }

    private static func stripSubshellParens(_ command: String) -> String {
        var result = command
        while result.hasPrefix("("), result.hasSuffix(")"), result.count >= 2 {
            // Verify the outer parens actually balance (not `(a) && (b)`).
            let inner = result.dropFirst().dropLast()
            var depth = 0
            var balanced = true
            for char in inner {
                if char == "(" { depth += 1 }
                if char == ")" {
                    depth -= 1
                    if depth < 0 { balanced = false; break }
                }
            }
            guard balanced, depth == 0 else { break }
            result = String(inner).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    // MARK: - File Redirects (spaced or not)

    /// Sensitive targets: writing here is persistence / trust subversion,
    /// not an ordinary file write → blocked.
    private static let sensitiveRedirectTargets = [
        ".bashrc", ".zshrc", ".bash_profile", ".profile",
        "/etc/cron", "/etc/sudoers", "/etc/passwd", "/etc/shadow",
        "authorized_keys", "launchdaemons", "launchagents", "/etc/hosts",
    ]

    /// Detect `>` / `>>` file redirects with or without surrounding spaces
    /// (`echo hi>/etc/x`, `2>file`). Quoted operators don't count;
    /// `<<` heredocs, `>&N` fd-duplication, `=>`/`>=` comparisons, and
    /// `/dev/null` sinks don't count either.
    private static func fileRedirectRisk(_ command: String) -> CommandSafety? {
        let chars = Array(command)
        var idx = chars.startIndex
        var inSingleQuote = false
        var inDoubleQuote = false
        var sawFileWrite = false
        while idx < chars.endIndex {
            let char = chars[idx]
            if char == "'", !inDoubleQuote { inSingleQuote.toggle(); idx = chars.index(after: idx); continue }
            if char == "\"", !inSingleQuote { inDoubleQuote.toggle(); idx = chars.index(after: idx); continue }
            guard char == ">", !inSingleQuote, !inDoubleQuote else {
                idx = chars.index(after: idx)
                continue
            }
            // `=>` / `>=` are comparisons, not redirects.
            if idx > chars.startIndex, chars[chars.index(before: idx)] == "=" {
                idx = chars.index(after: idx)
                continue
            }
            var next = chars.index(after: idx)
            // `<<` / `<<<` heredoc: no file target.
            if next < chars.endIndex, chars[next] == "<" {
                idx = chars.index(after: idx)
                continue
            }
            // `>>`: consume the second `>`.
            if next < chars.endIndex, chars[next] == ">" { next = chars.index(after: next) }
            // `>|` noclobber override: consume the `|`.
            if next < chars.endIndex, chars[next] == "|" { next = chars.index(after: next) }
            // `>&N` / `2>&N`: fd duplication, not a file write.
            if next < chars.endIndex, chars[next] == "&" {
                let afterAmp = chars.index(after: next)
                if afterAmp < chars.endIndex, chars[afterAmp].isNumber || chars[afterAmp] == "-" {
                    idx = chars.index(after: idx)
                    continue
                }
                next = afterAmp // `&>file`: target follows the `&`
            }
            // Parse the target token.
            var target = next
            while target < chars.endIndex, chars[target] == " " || chars[target] == "\t" { target = chars.index(after: target) }
            var targetEnd = target
            while targetEnd < chars.endIndex, !" \t;|&<>()".contains(chars[targetEnd]) { targetEnd = chars.index(after: targetEnd) }
            let targetText = String(chars[target..<targetEnd])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if targetText.lowercased().hasPrefix("/dev/null") {
                idx = targetEnd
                continue
            }
            if targetText.isEmpty {
                sawFileWrite = true // `echo hi >` — incomplete, stay suspicious
                idx = targetEnd
                continue
            }
            let lowerTarget = targetText.lowercased()
            if sensitiveRedirectTargets.contains(where: { lowerTarget.contains($0) }) {
                return .blocked
            }
            sawFileWrite = true
            idx = targetEnd
        }
        return sawFileWrite ? .moderate : nil
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
                } else if char.isNewline {
                    // Line separator. The shell this string reaches splits on
                    // it, so an unmodelled one let everything after it escape
                    // classification: "ls\nreboot" matched no exact-set entry,
                    // classified L1, and was allowed in every access mode while
                    // the remote shell ran both commands. Split only outside
                    // quotes, where a newline is a literal character to the
                    // shell as well.
                    //
                    // `isNewline` rather than comparing against a newline or
                    // carriage-return literal: Swift treats CRLF as ONE
                    // Character, so an equality check against either literal
                    // never matches a Windows line ending, and a CRLF pair
                    // stayed a single unclassified segment.
                    //
                    // A bare "&" is deliberately NOT handled here. It is a
                    // separator in most positions but a redirection operator in
                    // "2>&1", and splitting on it broke
                    // `CommandSafetyBypassTests.fdDuplicationRedirectsStaySafe`.
                    // Modelling it correctly needs redirection-context tracking,
                    // which is a separate change — tracked, not guessed at.
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
        // Newlines included, or a segment keeps a leading "\n" and misses the
        // exact-match sets below exactly as the whole command did.
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
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
        case .safe: L.t(.safe)
        case .moderate: L.t(.moderate)
        case .dangerous: L.t(.dangerous)
        case .blocked: L.t(.blocked)
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
