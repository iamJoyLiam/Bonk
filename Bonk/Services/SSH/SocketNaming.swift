//
//  SocketNaming.swift
//  Bonk
//
//  Single helper for ControlMaster socket path (Phase 3).
//  Previously built in 3 places with slightly different hashing.
//

import Foundation
import CryptoKit

enum SocketNaming {
    /// Deterministic ControlMaster socket path.
    /// Uses SHA256 of host:port:user to avoid collisions and stay under 104 char limit.
    static func controlPath(host: String, port: UInt16, username: String) -> String {
        let raw = "\(host):\(port):\(username)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        let dir = FileManager.default.temporaryDirectory.path
        return (dir as NSString).appendingPathComponent("bonk-\(hex).sock")
    }

    static func controlPath(for endpoint: SSHEndpoint, username: String) -> String {
        controlPath(host: endpoint.host, port: endpoint.port, username: username)
    }

    /// Legacy-compatible name for migration (FNV-1a, matches old code).
    static func legacyPath(host: String, port: UInt16, username: String) -> String {
        var hash: UInt64 = 14695981039346656037
        let raw = "\(host):\(port):\(username)"
        for bookmark in raw.utf8 {
            hash ^= UInt64(bookmark)
            hash &*= 1099511628211
        }
        let dir = FileManager.default.temporaryDirectory.path
        return (dir as NSString).appendingPathComponent("bonk-\(String(format: "%016llx", hash)).sock")
    }
}
