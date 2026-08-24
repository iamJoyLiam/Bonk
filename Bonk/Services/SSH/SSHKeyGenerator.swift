//
//  SSHKeyGenerator.swift
//  Bonk
//
//  SSH key generation service supporting Ed25519, RSA, and ECDSA.
//

import CryptoKit
import Foundation
import os.log
import Security

// MARK: - Key Type

/// Supported SSH key types.
enum SSHKeyType: String, CaseIterable, Sendable {
    case ed25519 = "Ed25519"
    case rsa2048 = "RSA 2048"
    case rsa4096 = "RSA 4096"
    case ecdsaP256 = "ECDSA P-256"
    case ecdsaP384 = "ECDSA P-384"

    var displayName: String { rawValue }

    var description: String {
        switch self {
        case .ed25519: "推荐：最快、最安全"
        case .rsa2048: "兼容性好，广泛支持"
        case .rsa4096: "高安全性 RSA"
        case .ecdsaP256: "椭圆曲线，平衡性能与安全"
        case .ecdsaP384: "更高安全性的椭圆曲线"
        }
    }
}

// MARK: - Generated Key

/// A generated SSH key pair.
struct GeneratedSSHKey: Sendable {
    let type: SSHKeyType
    let privateKeyPEM: String
    let publicKeySSH: String
    let fingerprint: String
}

// MARK: - Key Generator Errors

enum SSHKeyGeneratorError: Error, LocalizedError {
    case keyGenerationFailed(String)
    case invalidKeyFormat

    var errorDescription: String? {
        switch self {
        case let .keyGenerationFailed(reason):
            "Key generation failed: \(reason)"
        case .invalidKeyFormat:
            "Invalid key format"
        }
    }
}

// MARK: - SSH Key Generator

enum SSHKeyGenerator {
    private static let logger = Logger(subsystem: "com.bonk", category: "SSHKeyGen")

    /// Generate an SSH key pair.
    static func generate(type: SSHKeyType, passphrase: String? = nil) throws -> GeneratedSSHKey {
        logger.info("Generating \(type.displayName) key...")
        let trimmed = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPassphrase = trimmed != nil && !(trimmed!.isEmpty)
        // Prefer system ssh-keygen for correct OpenSSH format + passphrase encryption.
        // Falls back to CryptoKit/Security if ssh-keygen unavailable.
        if let result = try? generateViaSSHKeygen(type: type, passphrase: hasPassphrase ? trimmed : nil) {
            return result
        }
        // Fallback (no passphrase encryption)
        switch type {
        case .ed25519:
            return try generateEd25519(passphrase: trimmed)
        case .rsa2048:
            return try generateRSA(bits: 2048, passphrase: trimmed)
        case .rsa4096:
            return try generateRSA(bits: 4096, passphrase: trimmed)
        case .ecdsaP256:
            return try generateECDSA(bits: 256, passphrase: trimmed)
        case .ecdsaP384:
            return try generateECDSA(bits: 384, passphrase: trimmed)
        }
    }

    // MARK: - System ssh-keygen (correct OpenSSH v1 + passphrase)

    private static func generateViaSSHKeygen(type: SSHKeyType, passphrase: String?) throws -> GeneratedSSHKey {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("bonk-keygen-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }
        let keyPath = tmpDir.appendingPathComponent("key")
        let pubPath = tmpDir.appendingPathComponent("key.pub")

        var args: [String] = []
        switch type {
        case .ed25519:
            args = ["-t", "ed25519", "-f", keyPath.path, "-N", passphrase ?? "", "-C", "bonk@local"]
        case .rsa2048:
            args = ["-t", "rsa", "-b", "2048", "-f", keyPath.path, "-N", passphrase ?? "", "-C", "bonk@local"]
        case .rsa4096:
            args = ["-t", "rsa", "-b", "4096", "-f", keyPath.path, "-N", passphrase ?? "", "-C", "bonk@local"]
        case .ecdsaP256:
            args = ["-t", "ecdsa", "-b", "256", "-f", keyPath.path, "-N", passphrase ?? "", "-C", "bonk@local"]
        case .ecdsaP384:
            args = ["-t", "ecdsa", "-b", "384", "-f", keyPath.path, "-N", passphrase ?? "", "-C", "bonk@local"]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            throw SSHKeyGeneratorError.keyGenerationFailed("ssh-keygen failed: \(err)")
        }
        guard let privatePEM = try? String(contentsOf: keyPath, encoding: .utf8),
              let publicSSH = try? String(contentsOf: pubPath, encoding: .utf8) else {
            throw SSHKeyGeneratorError.keyGenerationFailed("Failed to read generated key")
        }
        let fingerprint = (try? fingerprintViaSSHKeygen(pubPath: pubPath)) ?? calculateFingerprintForSSHPublicKey(publicSSH)
        return GeneratedSSHKey(type: type, privateKeyPEM: privatePEM.trimmingCharacters(in: .whitespacesAndNewlines), publicKeySSH: publicSSH.trimmingCharacters(in: .whitespacesAndNewlines), fingerprint: fingerprint)
    }

    private static func fingerprintViaSSHKeygen(pubPath: URL) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = ["-lf", pubPath.path, "-E", "sha256"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Output: "256 SHA256:xxxxx ... (ED25519)"
        if let range = out.range(of: "SHA256:") {
            let after = out[range.upperBound...]
            let token = after.split(separator: " ").first ?? Substring("")
            return "SHA256:\(token)"
        }
        throw SSHKeyGeneratorError.keyGenerationFailed("Failed to parse fingerprint")
    }

    private static func calculateFingerprintForSSHPublicKey(_ ssh: String) -> String {
        let parts = ssh.split(separator: " ")
        guard parts.count >= 2, let data = Data(base64Encoded: String(parts[1])) else { return "SHA256:unknown" }
        let hash = SHA256.hash(data: data)
        let b64 = Data(hash).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    // MARK: - Ed25519 (fallback, no passphrase encryption)

    private static func generateEd25519(passphrase: String? = nil) throws -> GeneratedSSHKey {
        // Use CryptoKit for Ed25519 key generation
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        // Export private key as PEM
        let privateKeyData = privateKey.rawRepresentation
        let privateKeyPEM = formatEd25519PrivateKeyPEM(privateKeyData)

        // Export public key in SSH format
        let publicKeyData = publicKey.rawRepresentation
        let publicKeySSH = formatEd25519PublicKeySSH(publicKeyData)

        // Calculate fingerprint
        let fingerprint = calculateFingerprint(publicKeyData, type: "ssh-ed25519")

        return GeneratedSSHKey(
            type: .ed25519,
            privateKeyPEM: privateKeyPEM,
            publicKeySSH: publicKeySSH,
            fingerprint: fingerprint
        )
    }

    private static func formatEd25519PrivateKeyPEM(_ data: Data) -> String {
        // OpenSSH Ed25519 private key format
        let base64 = data.base64EncodedString()
        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(chunkBase64(base64))
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    private static func formatEd25519PublicKeySSH(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        return "ssh-ed25519 \(base64)"
    }

    // MARK: - RSA (fallback)

    private static func generateRSA(bits: Int, passphrase: String? = nil) throws -> GeneratedSSHKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey)
        else {
            let errorDescription = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SSHKeyGeneratorError.keyGenerationFailed(errorDescription)
        }

        // Export private key
        guard let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw SSHKeyGeneratorError.keyGenerationFailed("Failed to export private key")
        }
        let privateKeyPEM = formatRSAPrivateKeyPEM(privateKeyData)

        // Export public key in SSH format
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw SSHKeyGeneratorError.keyGenerationFailed("Failed to export public key")
        }
        let publicKeySSH = formatRSAPublicKeySSH(publicKeyData)

        // Calculate fingerprint
        let fingerprint = calculateFingerprint(publicKeyData, type: "ssh-rsa")

        return GeneratedSSHKey(
            type: bits == 2048 ? .rsa2048 : .rsa4096,
            privateKeyPEM: privateKeyPEM,
            publicKeySSH: publicKeySSH,
            fingerprint: fingerprint
        )
    }

    private static func formatRSAPrivateKeyPEM(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        return """
        -----BEGIN RSA PRIVATE KEY-----
        \(chunkBase64(base64))
        -----END RSA PRIVATE KEY-----
        """
    }

    private static func formatRSAPublicKeySSH(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        return "ssh-rsa \(base64)"
    }

    // MARK: - ECDSA (fallback)

    private static func generateECDSA(bits: Int, passphrase: String? = nil) throws -> GeneratedSSHKey {
        let keyType = bits == 256 ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeECSECPrimeRandom
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: keyType,
            kSecAttrKeySizeInBits as String: bits,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey)
        else {
            let errorDescription = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SSHKeyGeneratorError.keyGenerationFailed(errorDescription)
        }

        // Export private key
        guard let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw SSHKeyGeneratorError.keyGenerationFailed("Failed to export private key")
        }
        let privateKeyPEM = formatECDSAPrivateKeyPEM(privateKeyData)

        // Export public key in SSH format
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw SSHKeyGeneratorError.keyGenerationFailed("Failed to export public key")
        }
        let algorithm = bits == 256 ? "ecdsa-sha2-nistp256" : "ecdsa-sha2-nistp384"
        let publicKeySSH = "\(algorithm) \(publicKeyData.base64EncodedString())"

        // Calculate fingerprint
        let fingerprint = calculateFingerprint(publicKeyData, type: algorithm)

        return GeneratedSSHKey(
            type: bits == 256 ? .ecdsaP256 : .ecdsaP384,
            privateKeyPEM: privateKeyPEM,
            publicKeySSH: publicKeySSH,
            fingerprint: fingerprint
        )
    }

    private static func formatECDSAPrivateKeyPEM(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        let header = "EC PRIVATE KEY"
        return """
        -----BEGIN \(header)-----
        \(chunkBase64(base64))
        -----END \(header)-----
        """
    }

    // MARK: - Helpers

    /// Format base64 string with 64-character lines.
    private static func chunkBase64(_ base64: String) -> String {
        var result = ""
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            result += base64[index..<end] + "\n"
            index = end
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Calculate SSH fingerprint (SHA256).
    private static func calculateFingerprint(_ keyData: Data, type: String) -> String {
        // Prepend type length + type string
        let typeBytes = type.data(using: .utf8) ?? Data()
        var fullData = Data()
        fullData.append(UInt32(typeBytes.count).bigEndianData)
        fullData.append(typeBytes)
        fullData.append(keyData)

        // SHA256 hash
        let hash = SHA256.hash(data: fullData)
        let hashData = Data(hash)
        let base64 = hashData.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")

        return "SHA256:\(base64)"
    }
}

// MARK: - UInt32 Extension

extension UInt32 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
