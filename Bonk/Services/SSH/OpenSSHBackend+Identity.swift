#if os(macOS)
import Crypto
import Foundation

// MARK: - Identity & certificate files (extracted)

extension OpenSSHBackend {
    func prepareIdentityFiles() throws {
        switch config.authMethod {
        case let .privateKey(pemString):
            targetIdentityFile = try writeIdentityFile(pemString, suffix: ".key")
        case let .certificate(privateKeyPEM, certificatePEM):
            targetIdentityFile = try writeIdentityFile(privateKeyPEM, suffix: ".key")
            targetCertificateFile = try writeIdentityFile(certificatePEM, suffix: ".cert")
        case .password, .secureEnclaveKey:
            break
        }

        guard let jumpAuth = config.jumpHost?.authMethod else { return }
        switch jumpAuth {
        case let .privateKey(pemString):
            jumpIdentityFile = try writeIdentityFile(pemString, suffix: ".jump.key")
        case let .certificate(privateKeyPEM, certificatePEM):
            jumpIdentityFile = try writeIdentityFile(privateKeyPEM, suffix: ".jump.key")
            jumpCertificateFile = try writeIdentityFile(certificatePEM, suffix: ".jump.cert")
        case .password, .secureEnclaveKey:
            break
        }
    }

    func writeIdentityFile(_ contents: String, suffix: String) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/bonk-ssh-\(UUID().uuidString)\(suffix)")
        let fileContents = Self.openSSHCompatiblePrivateKey(contents, suffix: suffix)
        try Data(fileContents.utf8).write(to: url, options: [.atomic])
        _ = chmod(url.path, mode_t(0o600))
        return url
    }

    static func openSSHCompatiblePrivateKey(_ contents: String, suffix: String) -> String {
        guard suffix.hasSuffix(".key"),
              contents.contains("BEGIN OPENSSH PRIVATE KEY")
        else { return contents }

        let payload = contents
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        guard let seed = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              seed.count == 32,
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else { return contents }

        return encodeOpenSSHPrivateKey(seed: seed, publicKey: privateKey.publicKey.rawRepresentation)
    }

    static func encodeOpenSSHPrivateKey(seed: Data, publicKey: Data) -> String {
        var publicBlob = SSHBinaryWriter()
        publicBlob.writeString("ssh-ed25519")
        publicBlob.writeString(publicKey)

        var privateBlob = SSHBinaryWriter()
        let check = UInt32.random(in: UInt32.min ... UInt32.max)
        privateBlob.writeUInt32(check)
        privateBlob.writeUInt32(check)
        privateBlob.writeString("ssh-ed25519")
        privateBlob.writeString(publicKey)
        privateBlob.writeString(seed + publicKey)
        privateBlob.writeString("")

        let paddingLength = 8 - (privateBlob.data.count % 8)
        privateBlob.data.append(contentsOf: (1 ... paddingLength).map(UInt8.init))

        var key = SSHBinaryWriter()
        key.data.append(contentsOf: Array("openssh-key-v1\0".utf8))
        key.writeString("none")
        key.writeString("none")
        key.writeString(Data())
        key.writeUInt32(1)
        key.writeString(publicBlob.data)
        key.writeString(privateBlob.data)

        let base64 = key.data.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { offset in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(70, base64.distance(from: start, to: base64.endIndex)))
            return String(base64[start ..< end])
        }
        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(lines.joined(separator: "\n"))
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    struct SSHBinaryWriter {
        var data = Data()
        mutating func writeUInt32(_ value: UInt32) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        mutating func writeString(_ value: String) { writeString(Data(value.utf8)) }
        mutating func writeString(_ value: Data) {
            writeUInt32(UInt32(value.count))
            data.append(value)
        }
    }
}
#endif
