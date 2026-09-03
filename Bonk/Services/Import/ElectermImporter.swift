//
//  ElectermImporter.swift
//  Bonk – easy import from Electerm bookmarks
//

import Foundation

struct ElectermImporter: SessionImporter {
    let name = "Electerm"
    let fileExtensions = ["json"]

    func discoverDefaultLocations() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/electerm/bookmarks.json"),
            home.appendingPathComponent(".electerm/bookmarks.json"),
            home.appendingPathComponent("Library/Application Support/electerm/electerm-bookmarks.json"),
            home.appendingPathComponent(".config/electerm/bookmarks.json"),
            home.appendingPathComponent("Library/Application Support/electerm/config.json"),
        ]
    }

    func importSessions(from url: URL) throws -> [HostItem] {
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw SessionImportError.parseFailed("Invalid JSON")
        }

        var rawBookmarks: [[String: Any]] = []

        if let dict = obj as? [String: Any] {
            if let arr = dict["bookmarks"] as? [[String: Any]] { rawBookmarks = arr }
            else if let arr = dict["bookmarks_"] as? [[String: Any]] { rawBookmarks = arr }
            else if let arr = dict["sessions"] as? [[String: Any]] { rawBookmarks = arr }
            else if let dataDict = dict["data"] as? [String: Any], let arr = dataDict["bookmarks"] as? [[String: Any]] { rawBookmarks = arr }
            else if let host = dict["host"] as? String, !host.isEmpty { rawBookmarks = [dict] }
        } else if let arr = obj as? [[String: Any]] {
            rawBookmarks = arr
        }

        if rawBookmarks.isEmpty { throw SessionImportError.noSessionsFound }

        let hosts = rawBookmarks.compactMap { parseBookmark($0) }
        if hosts.isEmpty { throw SessionImportError.noSessionsFound }
        return hosts
    }

    private func parseBookmark(_ dict: [String: Any]) -> HostItem? {
        // Electerm bookmark fields vary: title/host/username/port/password/privateKey
        let title = (dict["title"] as? String) ?? (dict["name"] as? String) ?? (dict["id"] as? String) ?? "Imported"
        let host = (dict["host"] as? String) ?? (dict["hostname"] as? String) ?? (dict["ip"] as? String) ?? ""
        guard !host.isEmpty else { return nil }
        let port = (dict["port"] as? Int) ?? (dict["port"] as? String).flatMap { Int($0) } ?? SSHConstants.defaultPort
        let username = (dict["username"] as? String) ?? (dict["user"] as? String) ?? (dict["login"] as? String) ?? "root"

        // Bookmark may nest under "form" or "session"
        var password: String? = dict["password"] as? String
        var privateKey: String? = dict["privateKey"] as? String ?? dict["privateKeyPath"] as? String ?? dict["key"] as? String

        if let form = dict["form"] as? [String: Any] {
            if password == nil { password = form["password"] as? String }
            if privateKey == nil { privateKey = form["privateKey"] as? String ?? form["privateKeyPath"] as? String }
        }

        var authType: AuthType = .password
        var pem: String?
        var pwd: String?

        if let pk = privateKey, !pk.isEmpty {
            if pk.hasPrefix("-----BEGIN") {
                pem = pk; authType = .privateKey
            } else {
                let expanded = (pk as NSString).expandingTildeInPath
                if let content = try? String(contentsOfFile: expanded, encoding: .utf8), content.contains("BEGIN") {
                    pem = content; authType = .privateKey
                } else {
                    pem = pk; authType = .privateKey
                }
            }
        } else if let p = password, !p.isEmpty {
            pwd = p; authType = .password
        }

        return HostItem(name: title, host: host, port: port, username: username, authType: authType, password: pwd, privateKeyPEM: pem)
    }
}
