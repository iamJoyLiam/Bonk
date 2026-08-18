//
//  SSHHostParser.swift
//  Bonk
//
//  Parses user@host:port input into separate fields. Quick Connect passes the
//  raw search text into AddHostSheet, and users commonly paste the full
//  `user@host:port` form instead of filling three separate fields.
//

import Foundation

struct ParsedSSHHost: Equatable {
    var username: String?
    var host: String
    var port: Int?
}

enum SSHHostParser {
    static func parse(_ input: String) -> ParsedSSHHost {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var username: String?

        if let at = value.lastIndex(of: "@") {
            username = String(value[..<at])
            value = String(value[value.index(after: at)...])
        }

        var host = value
        var port: Int?

        if value.hasPrefix("[") {
            // IPv6 literal: [::1]:2222
            if let close = value.firstIndex(of: "]") {
                let addressStart = value.index(after: value.startIndex)
                host = String(value[addressStart ..< close])
                let afterClose = value.index(after: close)
                if afterClose < value.endIndex, value[afterClose] == ":" {
                    let portString = value[value.index(after: afterClose)...]
                    if let parsedPort = Int(portString), (1 ... 65535).contains(parsedPort) {
                        port = parsedPort
                    }
                }
            }
        } else if let colon = value.lastIndex(of: ":") {
            let portString = value[value.index(after: colon)...]
            if let parsedPort = Int(portString), (1 ... 65535).contains(parsedPort) {
                port = parsedPort
                host = String(value[..<colon])
            }
        }

        return ParsedSSHHost(username: username, host: host, port: port)
    }
}
