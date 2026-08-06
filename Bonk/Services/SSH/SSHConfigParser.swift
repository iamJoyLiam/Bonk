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
        var currentEntry: SSHConfigEntry?
        var globalOptions: [String: String] = [:]

        let lines = content.components(separatedBy: .newlines)
        let basePathDir = (basePath as NSString).deletingLastPathComponent

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            // Parse key-value pair
            let (key, value) = parseLine(trimmed)

            guard let key, let value else {
                continue
            }

            let lowerKey = key.lowercased()

            // Handle Include directive
            if lowerKey == "include" {
                // Save current entry before processing includes
                if let entry = currentEntry {
                    entries.append(entry)
                    currentEntry = nil
                }

                // Resolve include path and parse recursively
                let includePath = resolveIncludePath(value, relativeTo: basePathDir)
                if let includedEntries = try? parse(
                    contentsOfFile: includePath,
                    includedFiles: includedFiles
                ) {
                    entries.append(contentsOf: includedEntries)
                }
                continue
            }

            // Check if this is a new Host directive
            if lowerKey == "host" {
                // Save previous entry
                if let entry = currentEntry {
                    entries.append(entry)
                }

                // Check if this is a global Host *
                if value == "*" {
                    currentEntry = nil // Use global options for subsequent entries
                } else {
                    // Create new entry, inheriting global options
                    currentEntry = SSHConfigEntry(
                        alias: value,
                        hostname: nil,
                        port: nil,
                        user: nil,
                        identityFile: nil,
                        proxyJump: nil,
                        localForwards: [],
                        remoteForwards: []
                    )
                    applyOptions(to: &currentEntry!, options: globalOptions)
                }
            } else if currentEntry == nil {
                // Global option (before any Host or for Host *)
                globalOptions[lowerKey] = value
            } else {
                // Option for current host
                applyOption(to: &currentEntry!, key: lowerKey, value: value)
            }
        }

        // Don't forget the last entry
        if let entry = currentEntry {
            entries.append(entry)
        }

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

    /// Parse a single line into key-value pair.
    private static func parseLine(_ line: String) -> (String?, String?) {
        // Split by whitespace (first occurrence)
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)

        guard parts.count >= 2 else {
            return (nil, nil)
        }

        let key = String(parts[0])

        // Handle quoted values
        let valuePart = String(parts[1]).trimmingCharacters(in: .whitespaces)
        let value: String

        if valuePart.hasPrefix("\"") && valuePart.hasSuffix("\"") {
            // Remove quotes
            value = String(valuePart.dropFirst().dropLast())
        } else {
            value = valuePart
        }

        return (key, value)
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
