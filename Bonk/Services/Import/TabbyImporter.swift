//
//  TabbyImporter.swift
//  Bonk
//
//  Imports Tabby (https://tabby.sh) SSH profiles.
//  Supports JSON export and YAML config (config.yaml).
//  Tabby stores profiles as: { "profiles": [ { "name": "...", "type": "ssh", "options": { "host": "...", "port": 22, "user": "...", "auth": "password|privateKey", "password": "...", "privateKey": "path-or-pem" } } ] }
//

import Foundation

struct TabbyImporter: SessionImporter {
    let name = "Tabby"
    let fileExtensions = ["json", "yaml", "yml"]

    func discoverDefaultLocations() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".config/tabby/config.yaml"),
            home.appendingPathComponent(".config/tabby/config.yml"),
            home.appendingPathComponent("Library/Application Support/tabby/config.yaml"),
            home.appendingPathComponent(".tabby.json"),
        ]
    }

    func importSessions(from url: URL) throws -> [HostItem] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SessionImportError.parseFailed("Cannot read file: \(error.localizedDescription)")
        }
        // Try JSON first
        if let hosts = tryParseJSON(data: data) { return hosts }
        // Fallback to YAML (lightweight line parser, no Yams dependency)
        if let text = String(data: data, encoding: .utf8), let hosts = tryParseYAML(text: text) {
            return hosts
        }
        throw SessionImportError.parseFailed("Unsupported Tabby format (expected JSON or YAML with profiles)")
    }

    // MARK: - JSON

    private func tryParseJSON(data: Data) -> [HostItem]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var profiles: [[String: Any]]?
        if let dict = obj as? [String: Any], let arr = dict["profiles"] as? [[String: Any]] {
            profiles = arr
        } else if let arr = obj as? [[String: Any]] {
            profiles = arr
        } else if let dict = obj as? [String: Any], let config = dict["config"] as? [String: Any], let arr = config["profiles"] as? [[String: Any]] {
            profiles = arr
        }
        guard let list = profiles else { return nil }
        let hosts = list.compactMap { parseProfile($0) }
        return hosts.isEmpty ? nil : hosts
    }

    private func parseProfile(_ dict: [String: Any]) -> HostItem? {
        // Tabby profile may be nested under "options"
        let name = dict["name"] as? String ?? dict["title"] as? String ?? "Imported"
        let type = dict["type"] as? String ?? dict["group"] as? String ?? ""
        // Only SSH
        if !type.isEmpty, type != "ssh" { return nil }

        var options = dict["options"] as? [String: Any] ?? dict
        // Some exports flatten host at top level
        let host = (options["host"] as? String) ?? (dict["host"] as? String) ?? ""
        guard !host.isEmpty else { return nil }
        let port = (options["port"] as? Int) ?? (dict["port"] as? Int) ?? SSHConstants.defaultPort
        let user = (options["user"] as? String) ?? (options["username"] as? String) ?? (dict["user"] as? String) ?? ""

        // Auth
        let auth = (options["auth"] as? String) ?? (options["authType"] as? String) ?? ""
        let password = (options["password"] as? String)
        let privateKeyField = (options["privateKey"] as? String) ?? (options["privateKeyPath"] as? String) ?? (options["key"] as? String)

        var authType: AuthType = .password
        var pem: String?
        var pwd: String?
        if let privateKey = privateKeyField, !privateKey.isEmpty {
            if privateKey.hasPrefix("-----BEGIN") {
                pem = privateKey
                authType = .privateKey
            } else {
                // Treat as file path
                let expanded = (privateKey as NSString).expandingTildeInPath
                if let content = try? String(contentsOfFile: expanded, encoding: .utf8), content.contains("BEGIN") {
                    pem = content
                    authType = .privateKey
                } else {
                    // Fallback: store path as-is (user can fix)
                    pem = privateKey
                    authType = .privateKey
                }
            }
        } else if let pwdVal = password, !pwdVal.isEmpty {
            pwd = pwdVal
            authType = .password
        } else if auth.lowercased().contains("key") {
            authType = .privateKey
        }

        let hostItem = HostItem(name: name, host: host, port: port, username: user.isEmpty ? "root" : user, authType: authType, password: pwd, privateKeyPEM: pem)
        return hostItem
    }

    // MARK: - YAML (minimal line scanner)

    private func tryParseYAML(text: String) -> [HostItem]? {
        // Very small YAML subset: look for "- name:" blocks under "profiles:"
        guard text.contains("profiles:") || text.contains("name:") else { return nil }
        var hosts: [HostItem] = []
        var current: [String: String] = [:]
        var inProfiles = false
        var currentName: String?
        var currentHost: String?
        var currentPort: Int = 22
        var currentUser: String = ""
        var currentPassword: String?
        var currentKey: String?

        func flush() {
            if let host = currentHost, !host.isEmpty {
                let name = currentName ?? host
                let authType: AuthType = (currentKey != nil) ? .privateKey : .password
                let item = HostItem(name: name, host: host, port: currentPort, username: currentUser.isEmpty ? "root" : currentUser, authType: authType, password: currentPassword, privateKeyPEM: currentKey)
                hosts.append(item)
            }
            currentName = nil; currentHost = nil; currentPort = 22; currentUser = ""; currentPassword = nil; currentKey = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("profiles:") { inProfiles = true; continue }
            if !inProfiles { continue }
            // Detect new profile start: "- name:" or "- title:"
            if line.hasPrefix("- ") {
                // Flush previous
                if currentHost != nil { flush() }
                let rest = String(line.dropFirst(2))
                if rest.hasPrefix("name:") || rest.hasPrefix("title:") {
                    let val = rest.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    currentName = val
                }
                continue
            }
            if line.hasPrefix("name:") || line.hasPrefix("title:") {
                // If we already have a host, this is next block; but - name already handled
                if currentHost != nil, !line.hasPrefix(" ") { /* ignore */ }
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if currentName == nil { currentName = val }
            } else if line.hasPrefix("host:") {
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                currentHost = val
            } else if line.hasPrefix("port:") {
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                currentPort = Int(val) ?? 22
            } else if line.hasPrefix("user:") || line.hasPrefix("username:") {
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                currentUser = val
            } else if line.hasPrefix("password:") {
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                currentPassword = val
            } else if line.hasPrefix("privateKey:") || line.hasPrefix("privateKeyPath:") {
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                currentKey = val
            }
        }
        if currentHost != nil { flush() }
        return hosts.isEmpty ? nil : hosts
    }
}
