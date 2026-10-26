//
//  MCPAuthenticationManager.swift
//  Bonk
//
//  OAuth 2.1 authorization for MCP servers.
//
//  When an MCP server requires OAuth, the client must obtain an access
//  token before it can talk to the server. The flow is:
//
//  1. Open the user's browser to the server's authorization URL.
//  2. The user authenticates and authorizes Bonk.
//  3. The server redirects the browser to a localhost callback URL
//     with an authorization code.
//  4. Bonk's local callback server captures the code.
//  5. Bonk exchanges the code for an access token at the token URL.
//  6. The access token is stored and sent as a Bearer header.
//
//  **Configuration comes from the user's mcp.json**, not from anything
//  the model says. Nothing the model says can trigger an OAuth flow.
//
//  **Authentication failures are real failures.** A server that
//  requires OAuth but cannot be authenticated is reported as an error,
//  not silently mocked.
//

import Foundation
import os
import AppKit
import CryptoKit

/// Result of the OAuth authorization flow.
enum MCPAuthResult {
    case authorized
    case refused
    case failed(Error)
}

/// Manages OAuth authorization for MCP servers.
///
/// The manager coordinates between:
/// - `MCPOAuthCallbackServer` - listens for the redirect
/// - `MCPAuthStore` - persists tokens in the Keychain
/// - The system browser - opens the authorization URL
///
/// The manager is a pure decision layer: it produces an access token
/// or an error, and never converts a real failure into mock success.
final class MCPAuthenticationManager: @unchecked Sendable {
    static let logger = Logger(subsystem: "com.bonk", category: "MCP")

    private let store: MCPAuthStore

    init(store: MCPAuthStore = MCPAuthStore()) {
        self.store = store
    }

    /// Authorize the user for a server.
    ///
    /// If a valid token is already stored, returns immediately.
    /// Otherwise, starts the OAuth flow: opens a browser window for the
    /// user to authorize, waits for the redirect, exchanges the code for
    /// tokens, and stores them.
    ///
    /// Returns `.authorized` when the user has granted access, `.refused`
    /// when the user declined or closed the browser, or `.failed` when
    /// something went wrong.
    func authorize(server: MCPServerConfiguration) async -> MCPAuthResult {
        // Check for an existing valid token first.
        if let token = store.token(for: server.name),
           tokenIsValid(token) {
            Self.logger.info(
                "Using cached OAuth token for server '\(server.name, privacy: .public)'"
            )
            return .authorized
        }

        guard let oauthConfig = server.oauth else {
            Self.logger.error(
                "Server '\(server.name, privacy: .public)' requires OAuth but has no OAuth configuration"
            )
            return .failed(MCPAuthError.missingConfiguration)
        }

        // Start the callback server.
        guard let callbackServer = try? MCPOAuthCallbackServer(port: 0) else {
            Self.logger.error("OAuth callback server is unavailable")
            return .failed(MCPAuthError.callbackServerUnavailable)
        }

        // Build the authorization URL.
        let state = UUID().uuidString
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        let authURL = buildAuthorizationURL(
            config: oauthConfig,
            state: state,
            codeChallenge: codeChallenge
        )

        Self.logger.info(
            "Opening authorization URL for server '\(server.name, privacy: .public)'"
        )

        // Open the browser.
        guard NSWorkspace.shared.open(authURL) else {
            Self.logger.error("Failed to open authorization URL in browser")
            return .failed(MCPAuthError.browserOpenFailed)
        }

        // Wait for the redirect.
        do {
            let result = try await callbackServer.waitForRedirect(timeout: 300)
            switch result {
            case .authorizationCode(let code):
                return await exchangeCodeForToken(
                    config: oauthConfig,
                    code: code,
                    codeVerifier: codeVerifier,
                    serverName: server.name
                )
            case .error(let message):
                Self.logger.error(
                    "OAuth authorization error for server '\(server.name, privacy: .public)': \(message, privacy: .public)"
                )
                return .refused
            }
        } catch {
            Self.logger.error(
                "OAuth callback failed for server '\(server.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return .failed(MCPAuthError.callbackFailed(error))
        }
    }

    /// Get the stored access token for a server, if any.
    func accessToken(for server: String) -> String? {
        return store.token(for: server)?.accessToken
    }

    /// Revoke the stored token for a server.
    func revoke(for server: String) {
        store.delete(for: server)
    }

    // MARK: - Private

    /// Build the authorization URL for the OAuth flow.
    private func buildAuthorizationURL(
        config: OAuthServerConfig,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: config.authorizationURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components?.url ?? config.authorizationURL
    }

    /// Exchange the authorization code for an access token.
    private func exchangeCodeForToken(
        config: OAuthServerConfig,
        code: String,
        codeVerifier: String,
        serverName: String
    ) async -> MCPAuthResult {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]
        if let clientSecret = config.clientSecret {
            bodyComponents.queryItems?.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.logger.error(
                    "Token exchange failed for server '\(serverName, privacy: .public)': HTTP \(statusCode)"
                )
                return .failed(MCPAuthError.tokenExchangeFailed(statusCode))
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            let expiresAt = tokenResponse.expiresIn.map { Date(timeIntervalSinceNow: TimeInterval($0)) }

            let token = MCPAuthToken(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken,
                expiresAt: expiresAt,
                scopes: tokenResponse.scope.map { $0.components(separatedBy: " ") } ?? []
            )

            store.store(token, for: serverName)
            Self.logger.info(
                "OAuth token stored for server '\(serverName, privacy: .public)'"
            )
            return .authorized
        } catch {
            Self.logger.error(
                "Token exchange failed for server '\(serverName, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return .failed(MCPAuthError.tokenExchangeFailed((error as NSError).code))
        }
    }

    private func tokenIsValid(_ token: MCPAuthToken) -> Bool {
        guard let expiresAt = token.expiresAt else { return true }
        return expiresAt > Date()
    }

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .ascii) else { return verifier }
        let digest = SHA256.hash(data: data)
        let base64 = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return base64
    }
}

/// The result of a token exchange.
private struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope = "scope"
    }
}

/// Errors from the OAuth flow.
enum MCPAuthError: Error {
    case missingConfiguration
    case callbackServerUnavailable
    case browserOpenFailed
    case callbackFailed(Error)
    case tokenExchangeFailed(Int)
}
