//
//  CopilotService.swift
//  Bonk
//
//  GitHub Copilot authentication via device code flow.
//

import AppKit
import Combine
import Foundation
import os

@MainActor
final class CopilotService: ObservableObject {
    static let shared = CopilotService()

    private static let logger = Log.copilot

    // GitHub Copilot OAuth app credentials (same used by VS Code / Neovim plugins)
    private static let clientID = "Iv1.b507a08c87ecfe98"
    private static let scope = "read:user"
    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    private static let copilotTokenURL = URL(string: "https://api.github.com/copilot_internal/v2/token")!
    private static let verifyURL = URL(string: "https://github.com/login/device")!

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case error(String)
    }

    enum AuthState: Equatable {
        case signedOut
        case signingIn(userCode: String, interval: Int, expiresAt: Date)
        case signedIn(username: String)
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var authState: AuthState = .signedOut
    @Published var errorMessage: String?

    private var oauthToken: String?
    private var signInTask: Task<Void, Never>?

    private let tokenKey = "com.bonk.copilot.oauth_token"
    private let usernameKey = "com.bonk.copilot.username"

    private init() {
        // Restore persisted token from Keychain
        if let token = KeychainHelper.get(for: tokenKey),
           let username = KeychainHelper.get(for: usernameKey)
        {
            oauthToken = token
            authState = .signedIn(username: username)
            status = .running
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard status != .starting, status != .running else { return }
        status = .starting

        // If we have a stored token, validate it
        if oauthToken != nil {
            status = .running
            await checkAuthStatus()
        } else {
            status = .running
        }

        Self.logger.info("Copilot service started")
    }

    func stop() async {
        signInTask?.cancel()
        signInTask = nil
        status = .stopped
        Self.logger.info("Copilot service stopped")
    }

    // MARK: - Authentication

    func signIn() async throws {
        if status == .stopped {
            await start()
        }
        guard status == .running else {
            throw CopilotError.serverNotRunning
        }

        errorMessage = nil

        // Step 1: Request device code
        var request = URLRequest(url: Self.deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "client_id": Self.clientID,
            "scope": Self.scope,
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CopilotError.authenticationFailed("Failed to request device code")
        }

        let deviceResponse = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)

        // Copy user code to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deviceResponse.userCode, forType: .string)

        // Open browser
        if let url = URL(string: deviceResponse.verificationUri) {
            NSWorkspace.shared.open(url)
        }

        let expiresAt = Date().addingTimeInterval(TimeInterval(deviceResponse.expiresIn))
        authState = .signingIn(
            userCode: deviceResponse.userCode,
            interval: deviceResponse.interval,
            expiresAt: expiresAt
        )

        Self.logger.info("Device code requested: \(deviceResponse.userCode)")

        // Step 2: Poll for authorization
        signInTask?.cancel()
        signInTask = Task {
            await pollForToken(
                deviceCode: deviceResponse.deviceCode,
                interval: deviceResponse.interval,
                expiresIn: deviceResponse.expiresIn
            )
        }
    }

    func completeSignIn() async throws {
        // This is called by UI after user clicks "Complete Sign In"
        // The actual polling happens in signIn(), this just waits for result
        guard case .signingIn = authState else { return }

        // Wait for the sign-in task to complete
        await signInTask?.value

        guard case .signedIn = authState else {
            throw CopilotError.authenticationFailed("Sign-in not completed")
        }
    }

    func signOut() async {
        oauthToken = nil
        authState = .signedOut
        KeychainHelper.delete(for: tokenKey)
        KeychainHelper.delete(for: usernameKey)
        Self.logger.info("Signed out of GitHub Copilot")
    }

    // MARK: - Private

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async {
        let pollInterval = max(interval, 5)
        let maxAttempts = expiresIn / pollInterval
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))

        for _ in 0 ..< maxAttempts {
            guard !Task.isCancelled else { return }
            guard Date() < deadline else {
                await MainActor.run {
                    authState = .signedOut
                    errorMessage = L.t(.signInExpired)
                }
                return
            }

            try? await Task.sleep(for: .seconds(pollInterval))
            guard !Task.isCancelled else { return }

            do {
                var request = URLRequest(url: Self.tokenURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: String] = [
                    "client_id": Self.clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
                request.httpBody = try JSONEncoder().encode(body)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    continue
                }

                let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

                if let error = tokenResponse.error {
                    switch error {
                    case "authorization_pending":
                        continue
                    case "slow_down":
                        try? await Task.sleep(for: .seconds(5))
                        continue
                    case "expired_token":
                        await MainActor.run {
                            authState = .signedOut
                            errorMessage = L.t(.signInExpired)
                        }
                        return
                    case "access_denied":
                        await MainActor.run {
                            authState = .signedOut
                            errorMessage = L.t(.accessDenied)
                        }
                        return
                    default:
                        Self.logger.error("Token error: \(error)")
                        continue
                    }
                }

                guard let accessToken = tokenResponse.accessToken else { continue }

                let username = await fetchUsername(token: accessToken) ?? "unknown"

                await MainActor.run {
                    self.oauthToken = accessToken
                    self.authState = .signedIn(username: username)
                    KeychainHelper.set(accessToken, for: tokenKey)
                    KeychainHelper.set(username, for: usernameKey)
                }

                Self.logger.info("Signed in as \(username)")
                return
            } catch {
                Self.logger.error("Poll error: \(error.localizedDescription)")
                continue
            }
        }

        await MainActor.run {
            authState = .signedOut
            errorMessage = L.t(.signInTimedOut)
        }
    }

    private func fetchUsername(token: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/user") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct UserResponse: Decodable { let login: String }
            let response = try JSONDecoder().decode(UserResponse.self, from: data)
            return response.login
        } catch {
            Self.logger.error("Failed to fetch username: \(error.localizedDescription)")
            return nil
        }
    }

    private func checkAuthStatus() async {
        guard let token = oauthToken else {
            authState = .signedOut
            return
        }

        guard let username = await fetchUsername(token: token) else {
            oauthToken = nil
            authState = .signedOut
            KeychainHelper.delete(for: tokenKey)
            KeychainHelper.delete(for: usernameKey)
            return
        }
        authState = .signedIn(username: username)
    }

    // MARK: - Copilot Token (for API access)

    /// Fetch a short-lived Copilot API token using the OAuth token.
    func fetchCopilotToken() async throws -> String {
        guard let oauthToken else {
            throw CopilotError.authenticationFailed("Not signed in")
        }

        var request = URLRequest(url: Self.copilotTokenURL)
        request.setValue("Bearer \(oauthToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CopilotError.authenticationFailed("Failed to fetch Copilot token")
        }

        let tokenResponse = try JSONDecoder().decode(CopilotTokenResponse.self, from: data)
        return tokenResponse.token
    }
}

// MARK: - Models

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case error
        case errorDescription = "error_description"
    }
}

private struct CopilotTokenResponse: Decodable {
    let token: String
    let expiresAt: Int

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

// MARK: - Errors

enum CopilotError: Error, LocalizedError {
    case serverNotRunning
    case authenticationFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            "Copilot server is not running"
        case let .authenticationFailed(detail):
            "Authentication failed: \(detail)"
        }
    }
}
