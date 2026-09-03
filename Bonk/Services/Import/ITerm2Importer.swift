//
//  ITerm2Importer.swift
//  Bonk – easy import from iTerm2 plist / dynamic profiles
//

import Foundation

struct ITerm2Importer: SessionImporter {
    let name = "iTerm2"
    let fileExtensions = ["plist", "json"]

    func discoverDefaultLocations() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Preferences/com.googlecode.iterm2.plist"),
            home.appendingPathComponent("Library/Application Support/iTerm2/DynamicProfiles"),
        ]
    }

    func importSessions(from url: URL) throws -> [HostItem] {
        // Plist file
        if url.pathExtension.lowercased() == "plist" {
            return try parsePlist(url: url)
        }
        // Directory of dynamic profiles
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            var result: [HostItem] = []
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "json" {
                    if let hosts = try? parseDynamicJSON(url: fileURL) { result.append(contentsOf: hosts) }
                }
            }
            if result.isEmpty { throw SessionImportError.noSessionsFound }
            return result
        }
        // Single JSON dynamic profile
        if url.pathExtension.lowercased() == "json" {
            return try parseDynamicJSON(url: url)
        }
        throw SessionImportError.unsupportedFormat
    }

    // MARK: - Plist

    private func parsePlist(url: URL) throws -> [HostItem] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        var dicts: [[String: Any]] = []
        if let root = plist as? [String: Any] {
            if let arr = root["New Bookmarks"] as? [[String: Any]] { dicts.append(contentsOf: arr) }
            if let arr = root["Profiles"] as? [[String: Any]] { dicts.append(contentsOf: arr) }
            // Some versions store directly as array under root
            if dicts.isEmpty, let arr = root["Bookmarks"] as? [[String: Any]] { dicts.append(contentsOf: arr) }
        } else if let arr = plist as? [[String: Any]] {
            dicts = arr
        }
        if dicts.isEmpty { throw SessionImportError.noSessionsFound }
        let hosts = dicts.compactMap { parseProfile($0) }
        if hosts.isEmpty { throw SessionImportError.noSessionsFound }
        return hosts
    }

    private func parseProfile(_ dict: [String: Any]) -> HostItem? {
        // iTerm2 profile may have Name and Command / Custom Command
        let name = (dict["Name"] as? String) ?? (dict["name"] as? String) ?? (dict["Title"] as? String) ?? "Imported"
        // Command is like "ssh user@host -p 2222"
        let command = (dict["Command"] as? String) ?? (dict["Custom Command"] as? String) ?? (dict["command"] as? String) ?? ""
        guard !command.isEmpty, command.lowercased().contains("ssh") else { return nil }
        // Extract host/user/port from ssh command
        let parsed = parseSSHCommand(command)
        guard let host = parsed.host, !host.isEmpty else { return nil }
        let port = parsed.port ?? SSHConstants.defaultPort
        let user = parsed.user ?? "root"
        return HostItem(name: name, host: host, port: port, username: user)
    }

    private func parseSSHCommand(_ cmd: String) -> (host: String?, user: String?, port: Int?) {
        // Very tolerant: find user@host and -p port
        // Example: ssh -p 2222 user@1.2.3.4 -i ...
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract port via regex
        var port: Int?
        if let regex = try? NSRegularExpression(pattern: "(?:\\s|^)-p\\s+(\\d+)", options: .caseInsensitive) {
            let nsString = trimmed as NSString
            if let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: nsString.length)), match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                port = Int(nsString.substring(with: range))
            }
        }
        if port == nil, let regex2 = try? NSRegularExpression(pattern: "(?:\\s|^)-P\\s+(\\d+)", options: .caseInsensitive) {
            let nsString = trimmed as NSString
            if let match = regex2.firstMatch(in: trimmed, range: NSRange(location: 0, length: nsString.length)), match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                port = Int(nsString.substring(with: range))
            }
        }
        // Extract user@host - find last token containing @ or plain host
        // Split by space, find token with @ or with dots
        let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var host: String?
        var user: String?
        for token in tokens.reversed() {
            if token.hasPrefix("-") { continue }
            if token.contains("@") {
                let parts = token.split(separator: "@", maxSplits: 1)
                if parts.count == 2 {
                    user = String(parts[0])
                    host = String(parts[1])
                    break
                }
            } else if token.contains(".") || token.contains(":") || token == "localhost" {
                // plain host without user
                // Ensure not a flag value
                if host == nil, !token.contains("=") {
                    host = token
                }
            }
        }
        // Clean host from trailing ; or "
        if let hostString = host {
            host = hostString.trimmingCharacters(in: CharacterSet(charactersIn: "\"';"))
        }
        if let userString = user {
            user = userString.trimmingCharacters(in: CharacterSet(charactersIn: "\"';"))
        }
        return (host, user, port)
    }

    // MARK: - Dynamic JSON

    private func parseDynamicJSON(url: URL) throws -> [HostItem] {
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw SessionImportError.parseFailed("Invalid JSON")
        }
        var profiles: [[String: Any]] = []
        if let dict = obj as? [String: Any], let arr = dict["Profiles"] as? [[String: Any]] {
            profiles = arr
        } else if let arr = obj as? [[String: Any]] {
            profiles = arr
        } else if let dict = obj as? [String: Any], let arr = dict["profiles"] as? [[String: Any]] {
            profiles = arr
        }
        if profiles.isEmpty { throw SessionImportError.noSessionsFound }
        let hosts = profiles.compactMap { parseProfile($0) }
        if hosts.isEmpty { throw SessionImportError.noSessionsFound }
        return hosts
    }
}
