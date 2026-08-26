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
    static func makePool(
        config: SSHConnectionConfig,
        hostKeyStore: any SSHHostKeyStore,
        count: Int
    ) async throws -> [PooledSFTPHandle] {
        var handles: [PooledSFTPHandle] = []
        handles.reserveCapacity(count)
        do {
            try await withThrowingTaskGroup(of: PooledSFTPHandle.self) { group in
                for _ in 0..<count {
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
            // 清理已建半池
            for handle in handles { await handle.close() }
            throw error
        }
        Log.sftp.info("[POOL] N×TCP pool created count=\(handles.count) host=\(config.host)")
        return handles
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
