//
//  SecureEnclaveSSHKey.swift
//  Bonk
//
//  Secure Enclave-backed SSH key implementation using NIOSSHPrivateKeyProtocol.
//

import CryptoKit
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import Security

// MARK: - Secure Enclave Signature

/// NIOSSH signature backed by Secure Enclave.
struct SecureEnclaveSignature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "ecdsa-sha2-nistp256"

    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeInteger(UInt32(rawRepresentation.count))
        buffer.writeBytes(rawRepresentation)
        return 4 + rawRepresentation.count
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let length = buffer.readInteger(as: UInt32.self),
              let data = buffer.readData(length: Int(length))
        else {
            throw SecureEnclaveKeyError.invalidKeyData
        }
        return Self(rawRepresentation: data)
    }
}

// MARK: - Secure Enclave Public Key

/// NIOSSH public key backed by Secure Enclave P256 key.
struct SecureEnclavePublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "ecdsa-sha2-nistp256"

    let rawRepresentation: Data
    let backingKey: P256.Signing.PublicKey

    init(backingKey: P256.Signing.PublicKey) {
        self.backingKey = backingKey
        self.rawRepresentation = backingKey.x963Representation
    }

    func isValidSignature<D>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool where D: DataProtocol {
        guard let sig = signature as? SecureEnclaveSignature else { return false }
        do {
            let ecdsaSig = try P256.Signing.ECDSASignature(derRepresentation: sig.rawRepresentation)
            return backingKey.isValidSignature(ecdsaSig, for: Data(data))
        } catch {
            return false
        }
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        // ECDSA public key format: 04 + X (32 bytes) + Y (32 bytes)
        buffer.writeBytes(rawRepresentation)
        return rawRepresentation.count
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let data = buffer.readData(length: 65) else {
            throw SecureEnclaveKeyError.invalidKeyData
        }
        let publicKey = try P256.Signing.PublicKey(x963Representation: data)
        return Self(backingKey: publicKey)
    }
}

// MARK: - Secure Enclave Private Key

/// NIOSSH private key backed by Secure Enclave.
/// This key cannot be exported - signing happens in hardware.
struct SecureEnclavePrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = "ecdsa-sha2-nistp256"

    let publicKey: NIOSSHPublicKeyProtocol
    let keyTag: String

    /// Initialize with a key tag that identifies the Secure Enclave key in Keychain.
    init(keyTag: String, publicKey: P256.Signing.PublicKey) {
        self.keyTag = keyTag
        self.publicKey = SecureEnclavePublicKey(backingKey: publicKey)
    }

    /// Sign data using Secure Enclave.
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let signatureData = try SecureEnclaveKeyManager.sign(tag: keyTag, data: Data(data))
        return SecureEnclaveSignature(rawRepresentation: signatureData)
    }
}

// MARK: - Secure Enclave Key Manager

/// Manages Secure Enclave P256 keys for SSH authentication.
enum SecureEnclaveKeyManager {
    /// Keychain tag prefix for Secure Enclave keys.
    private static let keyTagPrefix = "com.bonk.ssh.secureenclave."

    /// Generate a new Secure Enclave P256 key pair.
    /// - Parameter tag: Unique identifier for the key (e.g., host ID or custom name)
    /// - Returns: The NIOSSH private key ready for use with Citadel
    @discardableResult
    static func generateKey(tag: String) throws -> SecureEnclavePrivateKey {
        let keyTag = keyTagPrefix + tag

        // Delete existing key if present
        deleteKey(tag: tag)

        // Access control: require user presence (biometric or password)
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &accessError
        ) else {
            let error = accessError?.takeRetainedValue()
            let description = error.map { String(describing: $0) } ?? "Unknown error"
            throw SecureEnclaveKeyError.keyGenerationFailed(description)
        }

        // Generate key in Secure Enclave
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
                kSecAttrAccessControl as String: accessControl,
            ] as [String: Any],
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let err = error?.takeRetainedValue()
            let description = err.map { String(describing: $0) } ?? "Unknown error"
            throw SecureEnclaveKeyError.keyGenerationFailed(description)
        }

        // Get public key data
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            throw SecureEnclaveKeyError.invalidKeyData
        }

        // Create P256 public key
        let p256PublicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)

        return SecureEnclavePrivateKey(keyTag: tag, publicKey: p256PublicKey)
    }

    /// Get an existing Secure Enclave private key.
    static func getPrivateKey(tag: String) throws -> SecureEnclavePrivateKey {
        let keyTag = keyTagPrefix + tag

        // Verify key exists and get public key
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let privateKey = item else {
            throw SecureEnclaveKeyError.keyNotFound
        }

        // Get public key
        guard let publicKey = SecKeyCopyPublicKey(privateKey as! SecKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else {
            throw SecureEnclaveKeyError.invalidKeyData
        }

        let p256PublicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)
        return SecureEnclavePrivateKey(keyTag: tag, publicKey: p256PublicKey)
    }

    /// Sign data using a Secure Enclave key.
    static func sign(tag: String, data: Data) throws -> Data {
        let keyTag = keyTagPrefix + tag

        // Get private key from Secure Enclave
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let privateKey = item else {
            throw SecureEnclaveKeyError.keyNotFound
        }

        // Sign the data (this triggers Touch ID / password prompt)
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey as! SecKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &signError
        ) as Data? else {
            let err = signError?.takeRetainedValue()
            let description = err.map { String(describing: $0) } ?? "Unknown error"
            throw SecureEnclaveKeyError.signingFailed(description)
        }

        return signature
    }

    /// Delete a Secure Enclave key.
    static func deleteKey(tag: String) {
        let keyTag = keyTagPrefix + tag
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Check if a Secure Enclave key exists for the given tag.
    static func keyExists(tag: String) -> Bool {
        let keyTag = keyTagPrefix + tag
        
        // Query for Secure Enclave keys specifically
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        
        // Log for debugging
        print("[SecureEnclave] Checking keyExists for tag: \(keyTag), status: \(status)")
        
        // errSecItemNotFound = -25300
        return status == errSecSuccess
    }

    /// Export the public key in OpenSSH format.
    static func exportPublicKey(tag: String) throws -> String {
        let keyTag = keyTagPrefix + tag

        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let privateKey = item else {
            throw SecureEnclaveKeyError.keyNotFound
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey as! SecKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else {
            throw SecureEnclaveKeyError.invalidKeyData
        }

        // Create OpenSSH format: ecdsa-sha2-nistp256 <base64>
        let base64Key = publicKeyData.base64EncodedString()
        return "ecdsa-sha2-nistp256 \(base64Key)"
    }
}

// MARK: - Errors

/// Errors related to Secure Enclave key operations.
enum SecureEnclaveKeyError: Error, LocalizedError {
    case keyGenerationFailed(String)
    case keyNotFound
    case signingFailed(String)
    case invalidKeyData

    var errorDescription: String? {
        switch self {
        case let .keyGenerationFailed(description):
            "Failed to generate Secure Enclave key: \(description)"
        case .keyNotFound:
            "Secure Enclave key not found"
        case let .signingFailed(description):
            "Failed to sign with Secure Enclave key: \(description)"
        case .invalidKeyData:
            "Invalid key data"
        }
    }
}
