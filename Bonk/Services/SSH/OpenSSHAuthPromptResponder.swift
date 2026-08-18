//
//  OpenSSHAuthPromptResponder.swift
//  Bonk
//
//  Bridges OpenSSH terminal prompts to saved credentials and MFA UI.
//

#if os(macOS)

import Foundation

/// Responds to authentication prompts emitted by an OpenSSH PTY.
///
/// Saved passwords are offered once. Further password prompts remain visible
/// so a user can correct a stale credential in the terminal. MFA prompts use
/// the same NSAlert controller as native keyboard-interactive auth.
struct OpenSSHPasswordCredential: Sendable, Equatable {
    let username: String
    let host: String
    let password: String
}

final class OpenSSHAuthPromptResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var promptBuffer = ""
    private var credentials: [OpenSSHPasswordCredential]
    private var interactivePromptInFlight = false
    private let allowInteractivePrompt: Bool
    /// Generic `Password:` prompts are ambiguous when a ProxyCommand is
    /// active. Only use them for single-hop commands that explicitly allow
    /// automatic password submission.
    private let allowUnscopedPassword: Bool
    private let write: @Sendable (Data) -> Void

    init(
        credentials: [OpenSSHPasswordCredential],
        allowInteractivePrompt: Bool,
        allowUnscopedPassword: Bool,
        write: @escaping @Sendable (Data) -> Void
    ) {
        self.credentials = credentials.filter { !$0.password.isEmpty }
        self.allowInteractivePrompt = allowInteractivePrompt
        self.allowUnscopedPassword = allowUnscopedPassword
        self.write = write
    }

    func observe(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

        lock.lock()
        promptBuffer.append(text)
        let normalized = Self.stripANSI(promptBuffer)
        let suffix = String(normalized.suffix(256))
        lock.unlock()

        if matchesPasswordPrompt(suffix) {
            if respondPasswordIfAvailable(for: suffix) {
                return
            }

            if allowInteractivePrompt {
                requestInteractivePrompt(label: "Password", echo: false)
            }
            return
        }

        guard allowInteractivePrompt, matchesInteractivePrompt(suffix) else { return }
        requestInteractivePrompt(label: Self.promptLabel(from: suffix), echo: false)
    }

    @discardableResult
    private func respondPasswordIfAvailable(for prompt: String) -> Bool {
        lock.lock()
        let promptLowercased = prompt.lowercased()
        let credentialIndex = credentials.firstIndex {
            let userHost = "\($0.username)@\($0.host)".lowercased()
            return promptLowercased.contains(userHost)
        } ?? (allowUnscopedPassword && credentials.count == 1 ? 0 : nil)

        guard let credentialIndex else {
            lock.unlock()
            return false
        }

        let credential = credentials.remove(at: credentialIndex)
        promptBuffer = ""
        lock.unlock()

        write(Data((credential.password + "\n").utf8))
        return true
    }

    private func requestInteractivePrompt(label: String, echo: Bool) {
        lock.lock()
        guard !interactivePromptInFlight else {
            lock.unlock()
            return
        }
        interactivePromptInFlight = true
        promptBuffer = ""
        lock.unlock()

        Task {
            defer { self.finishInteractivePrompt() }

            do {
                let responses = try await SSHKeyboardInteractivePromptController.promptText(
                    name: "SSH authentication required",
                    instruction: "Enter verification information.",
                    prompts: [(label: label, echo: echo)]
                )
                guard let response = responses.first else { return }
                self.write(Data((response + "\n").utf8))
            } catch {
                // Closing/cancelling prompt is handled by the child process.
            }
        }
    }

    private func finishInteractivePrompt() {
        lock.lock()
        interactivePromptInFlight = false
        lock.unlock()
    }

    private func matchesPasswordPrompt(_ text: String) -> Bool {
        text.range(
            of: #"(?i)(password|passphrase)\s*:\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private func matchesInteractivePrompt(_ text: String) -> Bool {
        text.range(
            of: #"(?i)(\bmfa\b|verification|one[- ]?time|otp|passcode|token|authenticator|code).{0,80}:\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func promptLabel(from text: String) -> String {
        let line = text
            .components(separatedBy: .newlines)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line?.isEmpty == false ? line! : "Verification code"
    }

    private static func stripANSI(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\u001B\[[0-?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\u001B\][^\u0007]*(?:\u0007|\u001B\\)"#,
                with: "",
                options: .regularExpression
            )
    }
}

#endif
