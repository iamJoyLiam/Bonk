//
//  SSHNetworkService+Backend.swift
//  Bonk
//
//  Backend helpers extracted from SSHNetworkService to keep the actor body
//  within size limits. Same-module extension: only internal members are used.
//

@preconcurrency import Citadel
import Crypto
import Foundation
import Network
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH
import os.log

// MARK: - SSHNetworkService Backend Helpers

extension SSHNetworkService {
    #if os(macOS)
        /// Start an OpenSSH-backed port forward for this connected target.
        func startPortForward(
            _ forward: SSHPortForwardConfiguration,
            onExit: @escaping @Sendable () -> Void
        ) async throws -> OpenSSHForwardHandle {
            guard usesOpenSSHTransport, let openSSHBackend else {
                throw SSHServiceError.connectionFailed(
                    "OpenSSH port forwarding requires an OpenSSH-backed connection."
                )
            }
            return try await openSSHBackend.startPortForward(config: forward, onExit: onExit)
        }
    #endif

    // MARK: - Host Key Verification (TOFU)

    func verifyHostKey(
        host: String,
        port: UInt16,
        fingerprint: SSHHostFingerprint?,
        store: any SSHHostKeyStore
    ) async throws {
        guard let fingerprint else {
            Log.ssh.error("No fingerprint computed for \(host):\(port), refusing connection")
            throw SSHServiceError.hostKeyMismatch(expected: "unknown", received: "none")
        }

        Log.ssh.info("Fingerprint for \(host):\(port): \(fingerprint.hash)")

        if let known = await store.knownFingerprint(for: host, port: port) {
            Log.ssh.info("Known fingerprint: \(known.hash)")
            guard known.hash == fingerprint.hash else {
                throw SSHServiceError.hostKeyMismatch(
                    expected: known.hash,
                    received: fingerprint.hash
                )
            }
        } else {
            Log.ssh.info("First connection, saving fingerprint")
            await store.saveFingerprint(fingerprint, for: host, port: port)
        }
    }

    // MARK: - Auth Mapping

    func mapAuthMethod(
        _ method: SSHAuthMethod,
        username: String
    ) throws -> SSHAuthenticationMethod {
        switch method {
        case let .password(password):
            return .passwordBased(username: username, password: password)

        case let .privateKey(pem):
            let raw = try decodePEM(pem)

            if let edKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                return .ed25519(username: username, privateKey: edKey)
            }

            throw SSHServiceError.connectionFailed(
                "Unsupported key type. Only Ed25519 private keys are supported. "
                    + "Detected key is not Ed25519 (raw \(raw.count) bytes)."
            )

        case let .certificate(privateKeyPEM, _):
            let raw = try decodePEM(privateKeyPEM)

            if let edKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                Log.ssh.info("Using certificate authentication for \(username)")
                return .ed25519(username: username, privateKey: edKey)
            }

            throw SSHServiceError.connectionFailed(
                "Certificate authentication requires an Ed25519 private key."
            )

        case let .secureEnclaveKey(keyTag):
            // Secure Enclave authentication: use custom NIOSSH key provider
            Log.ssh.info("Using Secure Enclave key for \(username)")
            let secureEnclaveKey = try SecureEnclaveKeyManager.getPrivateKey(tag: keyTag)
            return .custom(SecureEnclaveAuthDelegate(
                username: username,
                privateKey: secureEnclaveKey
            ))
        }
    }

    #if os(macOS)
        func shouldUseOpenSSH(_ method: SSHAuthMethod) -> Bool {
            if let forced = vnextForcedBackend {
                return forced == .compatibility
            }
            switch method {
            case .secureEnclaveKey:
                return false
            case .password, .privateKey, .certificate:
                return true
            }
        }

        /// VNext: force next connect to use a specific backend (T2.2).
        public func setVNextPreferredBackend(_ backend: SSHBackendType?) {
            vnextForcedBackend = backend
        }

        /// VNext T5 — vend a unified session for SFTP multiplexing on the same connection.
        public func makeVNextSession(endpoint: SSHEndpoint) -> (any SSHSession)? {
            #if os(macOS)
                if usesOpenSSHTransport, let backend = openSSHBackend {
                    return CompatibilitySSHSession(backend: backend, endpoint: endpoint)
                }
            #endif
            if let activeClient = client {
                if let cfg = config {
                    return NativeSSHSession(client: activeClient, endpoint: endpoint, config: cfg, hostKeyStore: hostKeyStore)
                }
                return NativeSSHSession(client: activeClient, endpoint: endpoint)
            }
            return nil
        }
    #endif

    private nonisolated func decodePEM(_ pem: String) throws -> Data {
        let base64 = pem
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()

        guard let data = Data(base64Encoded: base64) else {
            throw SSHServiceError.connectionFailed("Invalid base64 in PEM key")
        }
        return data
    }
}
