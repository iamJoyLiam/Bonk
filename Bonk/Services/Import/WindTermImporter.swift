//
//  WindTermImporter.swift
//  Bonk – easy import from WindTerm sessions
//

import Foundation

struct WindTermImporter: SessionImporter {
    let name = "WindTerm"
    let fileExtensions = ["json", "wsession"]

    func discoverDefaultLocations() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".windterm/profiles/default.v10/terminal/user.sessions"),
            home.appendingPathComponent(".windterm/profiles"),
            home.appendingPathComponent("Library/Application Support/windterm/profiles"),
            home.appendingPathComponent(".config/windterm/profiles"),
        ]
    }

    func importSessions(from url: URL) throws -> [HostItem] {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // Scan directory for json/wsession files
            var result: [HostItem] = []
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    let ext = fileURL.pathExtension.lowercased()
                    if ext == "json" || ext == "wsession" {
                        if let hosts = try? parseFile(url: fileURL) { result.append(contentsOf: hosts) }
                    }
                }
            }
            if result.isEmpty { throw SessionImportError.noSessionsFound }
            return result
        }
        return try parseFile(url: url)
    }

    private func parseFile(url: URL) throws -> [HostItem] {
        let data = try Data(contentsOf: url)
        // Try JSON
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            if let arr = obj as? [[String: Any]] {
                let hosts = arr.compactMap { parseDict($0) }
                if !hosts.isEmpty { return hosts }
            }
            if let dict = obj as? [String: Any] {
                // WindTerm may nest under "sessions" / "bookmarks" / "profiles"
                for key in ["sessions", "bookmarks", "profiles", "hosts", "data", "items"] {
                    if let arr = dict[key] as? [[String: Any]] {
                        let hosts = arr.compactMap { parseDict($0) }
                        if !hosts.isEmpty { return hosts }
                    }
                }
                // Single session dict
                if let host = parseDict(dict) { return [host] }
            }
        }
        // Fallback: try as INI-like key=value (WindTerm wsession may be custom)
        if let text = String(data: data, encoding: .utf8), text.contains("host") {
            if let hosts = parseWSessionText(text) { return hosts }
        }
        throw SessionImportError.noSessionsFound
    }

    private func parseDict(_ dict: [String: Any]) -> HostItem? {
        // WindTerm fields: sessionName / name, hostName / host, port, userName / username
        let name = (dict["sessionName"] as? String) ?? (dict["name"] as? String) ?? (dict["title"] as? String) ?? (dict["label"] as? String) ?? "Imported"
        // Host may be nested under "session" -> "host"
        var host: String? = (dict["hostName"] as? String) ?? (dict["host"] as? String) ?? (dict["hostname"] as? String) ?? (dict["ip"] as? String)
        var port: Int? = (dict["port"] as? Int) ?? (dict["port"] as? String).flatMap { Int($0) }
        var username: String? = (dict["userName"] as? String) ?? (dict["username"] as? String) ?? (dict["user"] as? String) ?? (dict["loginName"] as? String)

        if let session = dict["session"] as? [String: Any] {
            if host == nil { host = session["hostName"] as? String ?? session["host"] as? String }
            if port == nil { port = session["port"] as? Int ?? (session["port"] as? String).flatMap { Int($0) } }
            if username == nil { username = session["userName"] as? String ?? session["username"] as? String }
            // WindTerm ssh auth may be under session.auth
            if let auth = session["auth"] as? [String: Any] ?? session["authentication"] as? [String: Any] {
                let pwd = auth["password"] as? String
                let pk = auth["privateKey"] as? String ?? auth["key"] as? String ?? auth["privateKeyPath"] as? String
                if let h = host, !h.isEmpty {
                    let p = port ?? SSHConstants.defaultPort
                    let u = username ?? "root"
                    if let pkVal = pk, !pkVal.isEmpty {
                        let pem: String? = pkVal.hasPrefix("-----BEGIN") ? pkVal : (try? String(contentsOfFile: (pkVal as NSString).expandingTildeInPath, encoding: .utf8))
                        return HostItem(name: name, host: h, port: p, username: u, authType: .privateKey, privateKeyPEM: pem ?? pkVal)
                    }
                    if let pwdVal = pwd, !pwdVal.isEmpty {
                        return HostItem(name: name, host: h, port: p, username: u, authType: .password, password: pwdVal)
                    }
                    return HostItem(name: name, host: h, port: p, username: u)
                }
            }
        }

        guard let h = host, !h.isEmpty else { return nil }
        let p = port ?? SSHConstants.defaultPort
        let u = username ?? "root"

        // Password / key may be at top level
        let pwd = (dict["password"] as? String)
        let pk = (dict["privateKey"] as? String) ?? (dict["privateKeyPath"] as? String) ?? (dict["key"] as? String)

        if let pkVal = pk, !pkVal.isEmpty {
            let pem: String? = pkVal.hasPrefix("-----BEGIN") ? pkVal : (try? String(contentsOfFile: (pkVal as NSString).expandingTildeInPath, encoding: .utf8))
            return HostItem(name: name, host: h, port: p, username: u, authType: .privateKey, privateKeyPEM: pem ?? pkVal)
        }
        if let pwdVal = pwd, !pwdVal.isEmpty {
            return HostItem(name: name, host: h, port: p, username: u, authType: .password, password: pwdVal)
        }
        return HostItem(name: name, host: h, port: p, username: u)
    }

    private func parseWSessionText(_ text: String) -> [HostItem]? {
        // Very light parser for wsession INI-like lines: host = 1.2.3.4
        var dict: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(";") { continue }
            if t.contains("=") {
                let parts = t.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { dict[parts[0].lowercased()] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            } else if t.contains(":") {
                let parts = t.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { dict[parts[0].lowercased()] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            }
        }
        guard let host = dict["host"] ?? dict["hostname"] ?? dict["ip"] else { return nil }
        let name = dict["name"] ?? dict["sessionname"] ?? host
        let port = dict["port"].flatMap { Int($0) } ?? SSHConstants.defaultPort
        let user = dict["username"] ?? dict["user"] ?? "root"
        return [HostItem(name: name, host: host, port: port, username: user)]
    }
}
