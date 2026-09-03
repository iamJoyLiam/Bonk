//
//  GenericCSVImporter.swift
//  Bonk – easy import from generic CSV / JSON host lists
//

import Foundation

struct GenericCSVImporter: SessionImporter {
    let name = "CSV"
    let fileExtensions = ["csv", "txt", "json"]

    func discoverDefaultLocations() -> [URL] { [] }

    func importSessions(from url: URL) throws -> [HostItem] {
        let ext = url.pathExtension.lowercased()
        if ext == "json" {
            if let hosts = try? parseJSON(url: url), !hosts.isEmpty { return hosts }
            // Fall through to CSV try
        }
        return try parseCSV(url: url)
    }

    // MARK: - JSON generic

    private func parseJSON(url: URL) throws -> [HostItem] {
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw SessionImportError.parseFailed("Invalid JSON")
        }
        var arr: [[String: Any]] = []
        if let a = obj as? [[String: Any]] { arr = a }
        else if let d = obj as? [String: Any] {
            for key in ["hosts", "sessions", "bookmarks", "servers", "items", "data", "profiles"] {
                if let a = d[key] as? [[String: Any]] { arr = a; break }
            }
            if arr.isEmpty, let host = d["host"] as? String ?? d["hostname"] as? String, !host.isEmpty {
                arr = [d]
            }
        }
        if arr.isEmpty { throw SessionImportError.noSessionsFound }
        let hosts = arr.compactMap { parseDict($0) }
        if hosts.isEmpty { throw SessionImportError.noSessionsFound }
        return hosts
    }

    private func parseDict(_ dict: [String: Any]) -> HostItem? {
        // Flexible keys: name/title/alias, host/hostname/ip, port, username/user, password/privateKey
        let name = string(dict, keys: ["name", "title", "alias", "label", "displayName"]) ?? "Imported"
        let host = string(dict, keys: ["host", "hostname", "ip", "address", "server"]) ?? ""
        guard !host.isEmpty else { return nil }
        let portStr = string(dict, keys: ["port"])
        let port = portStr.flatMap { Int($0) } ?? (dict["port"] as? Int) ?? SSHConstants.defaultPort
        let username = string(dict, keys: ["username", "user", "login", "loginName"]) ?? "root"
        let password = string(dict, keys: ["password", "pwd", "pass"])
        let privateKey = string(dict, keys: ["privateKey", "privateKeyPath", "key", "pem"])

        if let pk = privateKey, !pk.isEmpty {
            if pk.hasPrefix("-----BEGIN") { return HostItem(name: name, host: host, port: port, username: username, authType: .privateKey, privateKeyPEM: pk) }
            let expanded = (pk as NSString).expandingTildeInPath
            if let content = try? String(contentsOfFile: expanded, encoding: .utf8), content.contains("BEGIN") {
                return HostItem(name: name, host: host, port: port, username: username, authType: .privateKey, privateKeyPEM: content)
            }
            return HostItem(name: name, host: host, port: port, username: username, authType: .privateKey, privateKeyPEM: pk)
        }
        if let pwd = password, !pwd.isEmpty {
            return HostItem(name: name, host: host, port: port, username: username, authType: .password, password: pwd)
        }
        return HostItem(name: name, host: host, port: port, username: username)
    }

    private func string(_ dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let v = dict[k] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v.trimmingCharacters(in: .whitespaces) }
            // case-insensitive
            for (dk, dv) in dict where dk.lowercased() == k.lowercased() {
                if let s = dv as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s.trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    // MARK: - CSV

    private func parseCSV(url: URL) throws -> [HostItem] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { throw SessionImportError.noSessionsFound }
        // Detect header
        let headerLine = lines[0]
        let hasHeader = headerLine.lowercased().contains("host") || headerLine.lowercased().contains("hostname") || headerLine.lowercased().contains("ip")
        var header: [String] = []
        var startIdx = 0
        if hasHeader {
            header = parseCSVLine(headerLine).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            startIdx = 1
        } else {
            // Assume order: name,host,port,username,password
            header = ["name", "host", "port", "username", "password"]
        }

        func idx(_ keys: [String]) -> Int? {
            for k in keys { if let i = header.firstIndex(where: { $0.contains(k) }) { return i } }
            return nil
        }
        let nameIdx = idx(["name", "title", "alias"])
        let hostIdx = idx(["host", "hostname", "ip", "address"]) ?? 1
        let portIdx = idx(["port"])
        let userIdx = idx(["user", "username", "login"])
        let passIdx = idx(["password", "pwd", "pass"])
        let keyIdx = idx(["key", "privatekey", "pem"])

        var result: [HostItem] = []
        for i in startIdx..<lines.count {
            let cols = parseCSVLine(lines[i])
            if cols.isEmpty { continue }
            func col(_ idx: Int?) -> String? {
                guard let idx, idx < cols.count else { return nil }
                let v = cols[idx].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v.isEmpty ? nil : v
            }
            let host = col(hostIdx) ?? ""
            if host.isEmpty { continue }
            let name = col(nameIdx) ?? host
            let port = col(portIdx).flatMap { Int($0) } ?? SSHConstants.defaultPort
            let user = col(userIdx) ?? "root"
            let pwd = col(passIdx)
            let pk = col(keyIdx)
            if let pkVal = pk, !pkVal.isEmpty {
                result.append(HostItem(name: name, host: host, port: port, username: user, authType: .privateKey, privateKeyPEM: pkVal))
            } else if let pwdVal = pwd, !pwdVal.isEmpty {
                result.append(HostItem(name: name, host: host, port: port, username: user, authType: .password, password: pwdVal))
            } else {
                result.append(HostItem(name: name, host: host, port: port, username: user))
            }
        }
        if result.isEmpty { throw SessionImportError.noSessionsFound }
        return result
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var quoteChar: Character = "\""
        for ch in line {
            if ch == "\"" || ch == "'" {
                if inQuotes && ch == quoteChar { inQuotes = false }
                else if !inQuotes { inQuotes = true; quoteChar = ch }
                else { current.append(ch) }
            } else if ch == "," && !inQuotes {
                result.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }
}
