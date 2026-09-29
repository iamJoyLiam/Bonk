import Foundation

// MARK: - Pairing helpers

extension TeamRelay {
    func allowPairingAttempt() -> Bool {
        let cutoff = Date().addingTimeInterval(-60)
        pairingFailureTimestamps.removeAll { $0 < cutoff }
        return pairingFailureTimestamps.count < TeamConstants.maxPairingFailuresPerMinute
    }

    func recordPairingFailure() {
        pairingFailureTimestamps.append(Date())
    }

    func sanitizedDisplayName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(64))
    }

    func currentActiveSessionID() -> TeamSessionID? {
        let sessionManager = injectedSessionManager ?? BonkAppDelegate.shared?.sessionManager
        guard let sessionManager, let tab = sessionManager.activeTab, let paneID = tab.activePaneID else { return nil }
        return TeamSessionID(tabID: tab.id, paneID: paneID)
    }

    func generatePin() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// Cryptographically random pairing nonce. 128 bits is enough: it exists
    /// to make a recorded `pairingAccepted` unusable against a later attempt.
    nonisolated static func makePairingNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return Data(bytes).base64EncodedString()
        }
        // Falling back to a UUID keeps the value unguessable enough to proceed;
        // a predictable nonce would remove the replay protection entirely.
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

// MARK: - Typing indicator

extension TeamRelay {
    func markTyping(peerID: UUID, displayName: String) {
        typingPeerName = sanitizedDisplayName(displayName, fallback: "Guest")
        typingClearTask?.cancel()
        typingClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.typingPeerName = nil
        }
    }

    func clearTyping() {
        typingClearTask?.cancel()
        typingClearTask = nil
        typingPeerName = nil
    }

    func notifyHostTyping() {
        guard let hostPeer else { return }
        markTyping(peerID: hostPeer.id, displayName: hostPeer.displayName)
        broadcastToGuests(.typing(peerID: hostPeer.id, displayName: hostPeer.displayName))
    }
}
