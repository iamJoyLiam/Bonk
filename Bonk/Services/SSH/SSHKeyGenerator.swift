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
        case .ed25519: L.t(.sshEd25519Desc)
        case .rsa2048: L.t(.sshRsa2048Desc)
        case .rsa4096: L.t(.sshRsa4096Desc)
        case .ecdsaP256: L.t(.sshEcdsaP256Desc)
        case .ecdsaP384: L.t(.sshEcdsaP384Desc)
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
        let requested = trimmed.flatMap { $0.isEmpty ? nil : $0 }

        if let requested {
            // An explicit passphrase is a requirement, not a hint. The CryptoKit
            // fallback cannot encrypt, so falling back to it would hand back an
            // unprotected private key while reporting success. When protection
            // was asked for, ssh-keygen is the only path and its failure
            // propagates.
            var secret = Array(requested.utf8)
            defer { zeroInPlace(&secret) }
            return try generateViaSSHKeygen(type: type, secret: secret)
        }

        // No passphrase requested: an unencrypted key is what was asked for, so
        // the fallback is a legitimate degradation here rather than a silent
        // withdrawal of a security control.
        // TEMPORARY DIAGNOSTIC. The failure reason already exists inside the
        // thrown error (it carries ssh-keygen's stderr); `try?` is what hides it.
        // Write it where the harness will not swallow it, then rethrow.
        let diagPath = "/private/var/folders/ql/gl8fnjcs0v90czmxh7h4rlqr0000gn/T/opencode/sshkeygen-diag.txt"
        func diag(_ line: String) {
            let existing = (try? String(contentsOfFile: diagPath, encoding: .utf8)) ?? ""
            try? Data((existing + line + "\n").utf8).write(to: URL(fileURLWithPath: diagPath))
        }
        diag("ENTER nil-path type=\(type.rawValue) tmpDir=\(NSTemporaryDirectory())")
        do {
            let result = try generateViaSSHKeygen(type: type, secret: nil)
            diag("SUCCESS pemHead=\(result.privateKeyPEM.prefix(40).debugDescription)")
            return result
        } catch {
            diag("THROW type=\(type.rawValue) error=\(error)")
            throw error
        }
        switch type {
        case .ed25519:
            return try generateEd25519()
        case .rsa2048:
            return try generateRSA(bits: 2048)
        case .rsa4096:
            return try generateRSA(bits: 4096)
        case .ecdsaP256:
            return try generateECDSA(bits: 256)
        case .ecdsaP384:
            return try generateECDSA(bits: 384)
        }
    }

    /// Best-effort overwrite of a buffer holding secret material.
    ///
    /// Not a guarantee, and deliberately not described as one: the runtime may
    /// hold other copies — bridged strings, register spills, swap — that this
    /// cannot reach.
    private static func zeroInPlace(_ bytes: inout [UInt8]) {
        for index in bytes.indices { bytes[index] = 0 }
    }

    /// Single-quote a path for safe use as one shell word.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Secret delivery

    /// Writes the passphrase to a file only this process and the askpass helper
    /// can read. Nothing else ever receives it.
    ///
    /// Returns the path so the caller cannot pass a different one to the helper.
    @discardableResult
    static func writeSecret(_ secret: [UInt8], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("secret")
        var payload = secret
        // ssh-keygen reads the passphrase as a line.
        payload.append(0x0A)
        try Data(payload).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        zeroInPlace(&payload)
        return url
    }

    /// Contents of the askpass helper.
    ///
    /// Its own function on purpose. An earlier version generated this as a side
    /// effect of building the invocation, which gave one abstraction two jobs and
    /// was the most likely reason the unprotected path regressed alongside the
    /// protected one.
    ///
    /// `$1` is OpenSSH's prompt text, never the secret, and is ignored here.
    static func makeAskpassHelper(secretPath: URL) -> String {
        "#!/bin/sh\n# argv[1] is OpenSSH's prompt text, not the secret.\n"
            + "exec cat " + shellQuoted(secretPath.path) + "\n"
    }

    @discardableResult
    static func writeAskpassHelper(secretPath: URL, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("askpass")
        try Data(makeAskpassHelper(secretPath: secretPath).utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path
        )
        return url
    }

    /// Environment additions for a protected invocation. Paths only.
    static func makeAskpassEnvironment(helperPath: URL) -> [String: String] {
        ["SSH_ASKPASS": helperPath.path, "SSH_ASKPASS_REQUIRE": "force"]
    }

    /// argv for ssh-keygen. Contains no secret under any circumstances, because
    /// it has no secret to contain: the passphrase is delivered by file path.
    static func makeArguments(type: SSHKeyType, keyPath: URL) -> [String] {
        var arguments: [String]
        switch type {
        case .ed25519:
            arguments = ["-t", "ed25519", "-f", keyPath.path, "-C", "bonk@local"]
        case .rsa2048:
            arguments = ["-t", "rsa", "-b", "2048", "-f", keyPath.path, "-C", "bonk@local"]
        case .rsa4096:
            arguments = ["-t", "rsa", "-b", "4096", "-f", keyPath.path, "-C", "bonk@local"]
        case .ecdsaP256:
            arguments = ["-t", "ecdsa", "-b", "256", "-f", keyPath.path, "-C", "bonk@local"]
        case .ecdsaP384:
            arguments = ["-t", "ecdsa", "-b", "384", "-f", keyPath.path, "-C", "bonk@local"]
        }
        return arguments
    }

    // MARK: - System ssh-keygen (correct OpenSSH v1 + passphrase)

    private static func generateViaSSHKeygen(type: SSHKeyType, secret: [UInt8]?) throws -> GeneratedSSHKey {
        let fileManager = FileManager.default
        let tmpDir = fileManager.temporaryDirectory.appendingPathComponent("bonk-keygen-\(UUID().uuidString)", isDirectory: true)
        // Explicit mode: the default temp permission is not a property to rely on
        // for a directory that will hold key material.
        try fileManager.createDirectory(
            at: tmpDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: tmpDir) }
        let keyPath = tmpDir.appendingPathComponent("key")
        let pubPath = tmpDir.appendingPathComponent("key.pub")

        var args = makeArguments(type: type, keyPath: keyPath)
        // Additions only. Assigning `Process.environment` replaces the child's
        // entire environment, so this must merge.
        var environmentAdditions: [String: String]?

        if secret == nil {
            // Nothing to protect. Ask for an empty passphrase explicitly so
            // ssh-keygen never prompts on a terminal we do not own.
            args += ["-N", ""]
        } else {
            // Deployment-floor guard, not an OpenSSH capability probe: it cannot
            // see the ssh-keygen version. The real enforcement is the non-zero
            // exit below — an ssh-keygen that ignores askpass never receives a
            // passphrase, cannot confirm, and exits non-zero.
            guard #available(macOS 13.0, *) else {
                throw SSHKeyGeneratorError.keyGenerationFailed(
                    "passphrase encryption requires macOS 13 or newer"
                )
            }
            let secretPath = try writeSecret(secret!, in: tmpDir)
            let helperPath = try writeAskpassHelper(secretPath: secretPath, in: tmpDir)
            environmentAdditions = makeAskpassEnvironment(helperPath: helperPath)
            // -N is deliberately absent: ssh-keygen prompts twice, for entry and
            // for confirmation, and the helper answers both.
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = args
        if let additions = environmentAdditions {
            var environment = ProcessInfo.processInfo.environment
            for (name, value) in additions { environment[name] = value }
            proc.environment = environment
        }
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

    private static func generateEd25519() throws -> GeneratedSSHKey {
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

    private static func generateRSA(bits: Int) throws -> GeneratedSSHKey {
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

    private static func generateECDSA(bits: Int) throws -> GeneratedSSHKey {
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
