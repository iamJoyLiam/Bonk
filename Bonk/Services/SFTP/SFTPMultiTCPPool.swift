//
//  SFTPMultiTCPPool.swift
//  Bonk — N×TCP 真并行连接池
//
//  为 >500MB 巨文件提供 N 条独立 SSH+ SFTP TCP 通道，突破单 TCP 拥塞窗口。
//  复用 SSHNetworkService.makeNativeClient 的认证与 HostKey 校验逻辑。

#if os(macOS)
import Citadel
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import os.log

// MARK: - Pooled SFTP Handle

/// 持有独立 SSHClient + SFTPClient，关闭时双关
final class PooledSFTPHandle: @unchecked Sendable {
    let sshClient: SSHClient
    let sftpClient: SFTPClient
    init(sshClient: SSHClient, sftpClient: SFTPClient) {
        self.sshClient = sshClient
        self.sftpClient = sftpClient
    }
    func close() async {
        try? await sftpClient.close()
        try? await sshClient.close()
    }
}

// MARK: - Factory

enum SFTPMultiTCPPool {
    /// 创建 N 条独立 SFTP 通道（每条新 TCP + SSH 握手 + SFTP 子系统）
    /// With rate limiting and MaxSessions adaptation: concurrency ≤2, 100ms per batch; auto half-retry on MaxSessions
    static func makePool(
        config: SSHConnectionConfig,
        hostKeyStore: any SSHHostKeyStore,
        count: Int
    ) async throws -> [PooledSFTPHandle] {
        // Adaptive: if request 8 but server MaxSessions=6, halve to 2
        var attemptCount = max(1, count)
        var lastError: Error?
        while attemptCount >= 1 {
            do {
                let pool = try await makePoolInternal(config: config, hostKeyStore: hostKeyStore, count: attemptCount)
                if attemptCount < count {
                    Log.sftp.warning("[POOL] MaxSessions probe: requested \(count) failed, succeeded with \(attemptCount) host=\(config.host)")
                }
                Log.sftp.info("[POOL] N×TCP pool created count=\(pool.count) host=\(config.host)")
                return pool
            } catch {
                lastError = error
                // Check MaxSessions/concurrency limit error
                if attemptCount > 2, isMaxSessionsError(error) {
                    let retry = max(2, attemptCount / 2)
                    Log.sftp.warning("[POOL] MaxSessions limit hit at \(attemptCount), retry \(retry) — \(String(describing: error))")
                    attemptCount = retry
                    // Backoff 300ms and retry to avoid immediate burst
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? SFTPServiceError.operationFailed("pool creation failed")
    }

    /// Internal creation — rate-limited concurrency 2, 100ms between batches
    private static func makePoolInternal(
        config: SSHConnectionConfig,
        hostKeyStore: any SSHHostKeyStore,
        count: Int
    ) async throws -> [PooledSFTPHandle] {
        var handles: [PooledSFTPHandle] = []
        handles.reserveCapacity(count)
        // Rate limit: concurrency 2, avoid burst hitting MaxStartups
        let maxConcurrent = 2
        var index = 0
        while index < count {
            let batchEnd = min(index + maxConcurrent, count)
            let batchCount = batchEnd - index
            do {
                try await withThrowingTaskGroup(of: PooledSFTPHandle.self) { group in
                    for _ in 0..<batchCount {
                        group.addTask {
                            let pair = try await makeOne(config: config, hostKeyStore: hostKeyStore)
                            return pair
                        }
                    }
                    for try await handle in group {
                        handles.append(handle)
                    }
                }
            } catch {
                for handle in handles { await handle.close() }
                throw error
            }
            index = batchEnd
            if index < count {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Check cancellation between batches
            if Task.isCancelled { throw CancellationError() }
        }
        return handles
    }

    /// Check if error is MaxSessions/channel limit
    private static func isMaxSessionsError(_ error: Error) -> Bool {
        let msg = String(describing: error).lowercased()
        let keywords = ["too many", "maxsessions", "administratively prohibited", "channel open failed", "too many sessions", "open failed", "session open error", "unable to open channel", "resource shortage"]
        return keywords.contains { msg.contains($0) }
    }

    private static func makeOne(config: SSHConnectionConfig, hostKeyStore: any SSHHostKeyStore) async throws -> PooledSFTPHandle {
        let sshClient = try await makeNativeClient(config: config, hostKeyStore: hostKeyStore)
        let sftpClient = try await sshClient.openSFTP()
        return PooledSFTPHandle(sshClient: sshClient, sftpClient: sftpClient)
    }

    // 复刻 SSHNetworkService.makeNativeClient（保持 HostKey TOFU 一致）
    private static func makeNativeClient(config: SSHConnectionConfig, hostKeyStore: any SSHHostKeyStore) async throws -> SSHClient {
        let citadelAuth = try mapAuthMethod(config.authMethod, username: config.username)
        let fingerprintBox = NIOLockedValueBox<SSHHostFingerprint?>(nil)
        let validator = HostKeyValidator { key in
            var buffer = ByteBuffer()
            key.write(to: &buffer)
            let bytes = Data(buffer.readableBytesView)
            let digest = SHA256.hash(data: bytes)
            let b64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
            fingerprintBox.withLockedValue { $0 = SSHHostFingerprint(hash: "SHA256:\(b64)") }
        }
        let sshClient = try await SSHClient.connect(
            host: config.host,
            port: Int(config.port),
            authenticationMethod: citadelAuth,
            hostKeyValidator: .custom(validator),
            reconnect: .never,
            algorithms: .all
        )
        // HostKey TOFU
        if let fingerprint = fingerprintBox.withLockedValue({ $0 }) {
            if let known = await hostKeyStore.knownFingerprint(for: config.host, port: config.port) {
                guard known.hash == fingerprint.hash else {
                    try? await sshClient.close()
                    throw SSHServiceError.hostKeyMismatch(expected: known.hash, received: fingerprint.hash)
                }
            } else {
                await hostKeyStore.saveFingerprint(fingerprint, for: config.host, port: config.port)
            }
        }
        return sshClient
    }

    private static func mapAuthMethod(_ method: SSHAuthMethod, username: String) throws -> SSHAuthenticationMethod {
        switch method {
        case let .password(password):
            return .passwordBased(username: username, password: password)
        case let .privateKey(pem):
            let raw = try decodePEM(pem)
            if let edKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                return .ed25519(username: username, privateKey: edKey)
            }
            throw SSHServiceError.connectionFailed("Unsupported key type. Only Ed25519 supported.")
        case let .certificate(privateKeyPEM, _):
            let raw = try decodePEM(privateKeyPEM)
            if let edKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                return .ed25519(username: username, privateKey: edKey)
            }
            throw SSHServiceError.connectionFailed("Certificate requires Ed25519.")
        case let .secureEnclaveKey(keyTag):
            let secureEnclaveKey = try SecureEnclaveKeyManager.getPrivateKey(tag: keyTag)
            return .custom(SecureEnclaveAuthDelegate(username: username, privateKey: secureEnclaveKey))
        }
    }

    private static func decodePEM(_ pem: String) throws -> Data {
        let base64 = pem.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined()
        guard let data = Data(base64Encoded: base64) else {
            throw SSHServiceError.connectionFailed("Invalid base64 in PEM")
        }
        return data
    }
}
#endif