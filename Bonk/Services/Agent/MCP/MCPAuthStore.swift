//
//  MCPAuthStore.swift
//  Bonk
//
//  Storage for OAuth tokens obtained from MCP servers.
//
//  Tokens are sensitive: they are access credentials to remote services.
//  They are stored in the macOS Keychain so that they survive app
//  relaunches and are protected by the user's login keychain.
//

import Foundation
import os

/// One OAuth token for an MCP server.
struct MCPAuthToken: Sendable, Equatable, Codable {
    /// The access token used in Bearer authorization headers.
    let accessToken: String
    /// Optional refresh token for obtaining new access tokens.
    let refreshToken: String?
    /// When the access token expires, if the server said.
    let expiresAt: Date?
    /// The scopes the token covers.
    let scopes: [String]
}

/// Stores and retrieves OAuth tokens for MCP servers.
///
/// Tokens are keyed by server name and stored in the macOS Keychain.
/// A missing keychain or a missing token is not an error: it simply
/// means the user has not yet authorized that server.
final class MCPAuthStore {
    private static let logger = Logger(subsystem: "com.bonk", category: "MCP")
    private static let service = "com.bonk.mcp"

    /// Read the stored token for a server.
    ///
    /// Returns nil when there is no stored token: the server has not
    /// been authorized yet, or the token has been deleted.
    func token(for server: String) -> MCPAuthToken? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPAuthStore.service,
            kSecAttrAccount as String: server,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let token = try? JSONDecoder().decode(MCPAuthToken.self, from: data)
        else {
            if status != errSecItemNotFound {
                MCPAuthStore.logger.error(
                    "Keychain read failed for server '\(server, privacy: .public)': \(status)"
                )
            }
            return nil
        }
        return token
    }

    /// Store a token for a server, replacing any existing token.
    func store(_ token: MCPAuthToken, for server: String) {
        let data: Data
        do {
            data = try JSONEncoder().encode(token)
        } catch {
            MCPAuthStore.logger.error(
                "Failed to encode token for server '\(server, privacy: .public)': \(error)"
            )
            return
        }

        // Delete any existing item first, then add.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPAuthStore.service,
            kSecAttrAccount as String: server
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPAuthStore.service,
            kSecAttrAccount as String: server,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            MCPAuthStore.logger.error(
                "Keychain write failed for server '\(server, privacy: .public)': \(status)"
            )
        }
    }

    /// Remove the stored token for a server.
    func delete(for server: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPAuthStore.service,
            kSecAttrAccount as String: server
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// All stored tokens, for diagnostics.
    var allTokens: [String: MCPAuthToken] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MCPAuthStore.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [:] }

        var tokens: [String: MCPAuthToken] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let token = try? JSONDecoder().decode(MCPAuthToken.self, from: data)
            else { continue }
            tokens[account] = token
        }
        return tokens
    }
}
