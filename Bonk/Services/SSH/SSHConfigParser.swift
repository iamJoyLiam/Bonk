//
//  SSHConfigParser.swift
//  Bonk
//
//  Parses ~/.ssh/config files for import into Bonk.
//  Supports Include directives for recursive parsing.
//

import Foundation
import os.log

// MARK: - SSH Config Entry

/// A single parsed SSH config entry.
struct SSHConfigEntry: Identifiable, Sendable {
    let id = UUID()
    var alias: String
    var hostname: String?
    var port: UInt16?
    var user: String?
    var identityFile: String?
    var proxyJump: String?
    var localForwards: [PortForwardEntry]
    var remoteForwards: [PortForwardEntry]

    struct PortForwardEntry: Sendable {
        var localPort: UInt16
        var remoteHost: String
        var remotePort: UInt16
    }
}

// MARK: - Parser Errors

enum SSHConfigError: Error, LocalizedError {
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            "SSH config file not found: \(path)"
        }
    }
}

// MARK: - SSH Config Parser

enum SSHConfigParser {
    private static let logger = Logger(subsystem: "com.bonk", category: "SSHConfig")

    /// Default SSH config path.
    static var defaultConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ssh/config").path
    }

    /// Parse the default ~/.ssh/config file.
    static func parse() throws -> [SSHConfigEntry] {
        try parse(contentsOfFile: defaultConfigPath)
    }

    /// Parse a specific SSH config file, with Include support.
    static func parse(contentsOfFile path: String, includedFiles: Set<String> = []) throws -> [SSHConfigEntry] {
        let fileManager = FileManager.default
        let resolvedPath = resolvePath(path)

        // Check if file exists
        guard fileManager.fileExists(atPath: resolvedPath) else {
            logger.warning("SSH config file not found: \(resolvedPath)")
            return []
        }

        // Prevent circular includes
        guard !includedFiles.contains(resolvedPath) else {
            logger.warning("Circular include detected, skipping: \(resolvedPath)")
            return []
        }

        var newIncludedFiles = includedFiles
        newIncludedFiles.insert(resolvedPath)

        // Read file contents
        guard let data = fileManager.contents(atPath: resolvedPath),
              let content = String(data: data, encoding: .utf8)
        else {
            throw SSHConfigError.fileNotFound(resolvedPath)
        }

        return parseContent(content, basePath: resolvedPath, includedFiles: newIncludedFiles)
    }

    /// Parse SSH config content string with Include support.
    static func parseContent(
        _ content: String,
        basePath: String = "",
        includedFiles: Set<String> = []
    ) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var currentEntries: [SSHConfigEntry] = []
        var globalOptions: [String: String] = [:]

        let lines = content.components(separatedBy: .newlines)
        let basePathDir = (basePath as NSString).deletingLastPathComponent

        func flushCurrent() {
            entries.append(contentsOf: currentEntries)
            currentEntries.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let (key, value) = parseLine(trimmed)
            guard let key, let value else { continue }
            let lowerKey = key.lowercased()

            if lowerKey == "include" {
                flushCurrent()
                // Include may contain multiple space-separated patterns with wildcards
                let patterns = value.split(separator: " ").map(String.init)
                for pattern in patterns where !pattern.isEmpty {
                    let raw = resolveIncludePath(pattern, relativeTo: basePathDir)
                    for expanded in expandGlob(raw) {
                        if let includedEntries = try? parse(contentsOfFile: expanded, includedFiles: includedFiles) {
                            entries.append(contentsOf: includedEntries)
                        }
                    }
                }
                continue
            }

            if lowerKey == "host" {
                flushCurrent()
                if value == "*" {
                    // Global Host * — subsequent options go to globalOptions
                    continue
                }
                let aliases = value.split(separator: " ").map { String($0) }.filter { !$0.isEmpty && $0 != "*" }
                // Filter out negated patterns (!host) — not imported
                let validAliases = aliases.filter { !$0.hasPrefix("!") && !$0.contains("?") && !$0.contains("*") }
                for alias in validAliases {
                    var entry = SSHConfigEntry(
                        alias: alias,
                        hostname: nil, port: nil, user: nil,
                        identityFile: nil, proxyJump: nil,
                        localForwards: [], remoteForwards: []
                    )
                    applyOptions(to: &entry, options: globalOptions)
                    currentEntries.append(entry)
                }
                // If all aliases were wildcards/negated, keep empty so globalOptions still applies but no entry
                if validAliases.isEmpty && !aliases.isEmpty {
                    // Wildcard host like "Host *.example.com" — treat as global-ish, no concrete entry
                    currentEntries = []
                }
            } else if currentEntries.isEmpty {
                globalOptions[lowerKey] = value
            } else {
                // swiftlint:disable:next identifier_name
                for i in currentEntries.indices {
                    applyOption(to: &currentEntries[i], key: lowerKey, value: value)
                }
            }
        }
        flushCurrent()
        logger.info("Parsed \(entries.count) SSH config entries from \(URL(fileURLWithPath: basePath).lastPathComponent)")
        return entries
    }

    // MARK: - Path Resolution

    /// Resolve ~ and relative paths.
    static func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    /// Resolve Include path (supports ~ and relative paths).
    static func resolveIncludePath(_ includePath: String, relativeTo basePath: String) -> String {
        let expanded = NSString(string: includePath).expandingTildeInPath

        // If path is absolute, return it
        if (expanded as NSString).isAbsolutePath {
            return expanded
        }

        // If relative, resolve against base path
        if !basePath.isEmpty {
            return (basePath as NSString).appendingPathComponent(expanded)
        }

        return expanded
    }

    /// Expand glob patterns (e.g., ~/.ssh/config.d/*) into actual file paths.
    static func expandGlob(_ pattern: String) -> [String] {
        let expanded = NSString(string: pattern).expandingTildeInPath

        // Use glob() to expand patterns
        var globResult = glob_t()
        defer { globfree(&globResult) }

        let cPattern = (expanded as NSString).fileSystemRepresentation
        let flags = GLOB_ERR | GLOB_MARK | GLOB_NOSORT | GLOB_DOOFFS
        let ret = glob(cPattern, flags, nil, &globResult)

        guard ret == 0 else {
            // If glob fails, return the original path (file might not exist yet)
            return [expanded]
        }

        var paths: [String] = []
        // swiftlint:disable:next identifier_name
        for i in 0 ..< globResult.gl_pathc {
            if let path = globResult.gl_pathv[i] {
                let pathString = String(cString: path)
                // Skip directories (marked with / by GLOB_MARK)
                if !pathString.hasSuffix("/") {
                    paths.append(pathString)
                }
            }
        }

        return paths.isEmpty ? [expanded] : paths
    }

    // MARK: - Line Parsing

    /// Parse a single line into key-value pair. Supports both `Key value` and `Key=value` forms.
    private static func parseLine(_ line: String) -> (String?, String?) {
        // Normalize "=" to space so "Host=foo" and "Port=22" are handled
        let normalized = line.replacingOccurrences(of: "=", with: " ")
        let parts = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return (nil, nil) }
        let key = String(parts[0])
        var valuePart = String(parts[1]).trimmingCharacters(in: .whitespaces)
        // Handle quoted values
        if (valuePart.hasPrefix("\"") && valuePart.hasSuffix("\"")) || (valuePart.hasPrefix("'") && valuePart.hasSuffix("'")) {
            valuePart = String(valuePart.dropFirst().dropLast())
        }
        return (key, valuePart)
    }

    // MARK: - Option Application

    /// Apply a single option to an entry.
    private static func applyOption(to entry: inout SSHConfigEntry, key: String, value: String) {
        switch key {
        case "hostname":
            entry.hostname = value
        case "port":
            if let port = UInt16(value) {
                entry.port = port
            }
        case "user":
            entry.user = value
        case "identityfile":
            // Expand ~ if present
            let expanded = NSString(string: value).expandingTildeInPath
            entry.identityFile = expanded
        case "proxyjump":
            entry.proxyJump = value
        case "localforward":
            if let forward = parsePortForward(value) {
                entry.localForwards.append(forward)
            }
        case "remoteforward":
            if let forward = parseRemoteForward(value) {
                entry.remoteForwards.append(forward)
            }
        default:
            // Ignore unsupported options
            break
        }
    }

    /// Apply multiple options to an entry.
    private static func applyOptions(to entry: inout SSHConfigEntry, options: [String: String]) {
        for (key, value) in options {
            applyOption(to: &entry, key: key, value: value)
        }
    }

    // MARK: - Port Forward Parsing

    /// Parse local forward specification: "8080 localhost:80" or "8080 127.0.0.1:80"
    private static func parsePortForward(_ value: String) -> SSHConfigEntry.PortForwardEntry? {
        let parts = value.split(separator: " ")
        guard parts.count >= 2,
              let localPort = UInt16(parts[0]),
              let (host, port) = parseHostPort(String(parts[1]))
        else {
            return nil
        }

        return SSHConfigEntry.PortForwardEntry(
            localPort: localPort,
            remoteHost: host,
            remotePort: port
        )
    }

    /// Parse remote forward specification: "3000 localhost:3000"
    private static func parseRemoteForward(_ value: String) -> SSHConfigEntry.PortForwardEntry? {
        let parts = value.split(separator: " ")
        guard parts.count >= 2,
              let remotePort = UInt16(parts[0]),
              let (host, port) = parseHostPort(String(parts[1]))
        else {
            return nil
        }

        return SSHConfigEntry.PortForwardEntry(
            localPort: port,
            remoteHost: host,
            remotePort: remotePort
        )
    }

    /// Parse "host:port" string.
    private static func parseHostPort(_ value: String) -> (String, UInt16)? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let port = UInt16(parts[1])
        else {
            return nil
        }

        return (String(parts[0]), port)
    }
}
