//===----------------------------------------------------------------------===//
//
//  AESCTR.swift
//  NIOSSH
//
//  AES-CTR transport protection (aes128-ctr / aes192-ctr / aes256-ctr)
//  with hmac-sha1 / hmac-sha1-96 / hmac-sha2-256 / hmac-sha2-512 MACs.
//  Needed for older bastions and network gear that only offer AES-CTR
//  ciphers (no GCM).
//
//===----------------------------------------------------------------------===//

import CCryptoBoringSSL
import Crypto
import Foundation
import NIO

enum AESCTRError: Error {
    case invalidMac
    case invalidKeySize
    case cryptographicError
    case invalidEncryptedPacketLength
    case invalidDecryptedPlaintextLength
}

/// Base implementation of AES-CTR with a separate HMAC for integrity.
open class AESCTRTransportProtection: NIOSSHTransportProtection {
    /// Subclasses provide the wire cipher name.
    open class var cipherName: String {
        fatalError("Subclass must override cipherName")
    }

    /// Subclasses provide the AES key size in bytes (16/24/32).
    open class var cipherKeySize: Int {
        fatalError("Subclass must override cipherKeySize")
    }

    public static let macNames = [
        "hmac-sha1",
        "hmac-sha1-96",
        "hmac-sha2-256",
        "hmac-sha2-512",
    ]
    public static let cipherBlockSize = 16

    private enum Mac {
        case sha1
        case sha1_96
        case sha256
        case sha512

        var tagBytes: Int {
            switch self {
            case .sha1_96: 12
            case .sha1: Insecure.SHA1.byteCount
            case .sha256: SHA256.byteCount
            case .sha512: SHA512.byteCount
            }
        }
    }

    public static func keySizes(forMac mac: String?) throws -> ExpectedKeySizes {
        let macKeySize: Int
        switch mac {
        case "hmac-sha1", "hmac-sha1-96":
            macKeySize = Insecure.SHA1.byteCount
        case "hmac-sha2-256":
            macKeySize = SHA256.byteCount
        case "hmac-sha2-512":
            macKeySize = SHA512.byteCount
        default:
            throw AESCTRError.invalidMac
        }
        return ExpectedKeySizes(
            ivSize: 16,
            encryptionKeySize: cipherKeySize,
            macKeySize: macKeySize
        )
    }

    public var macBytes: Int {
        mac.tagBytes
    }

    private var keys: NIOSSHSessionKeys
    private var decryptionContext: UnsafeMutablePointer<EVP_CIPHER_CTX>
    private var encryptionContext: UnsafeMutablePointer<EVP_CIPHER_CTX>
    private let mac: Mac

    public required init(initialKeys: NIOSSHSessionKeys, mac: String?) throws {
        let keySizes = try Self.keySizes(forMac: mac)
        guard
            initialKeys.outboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8,
            initialKeys.inboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8
        else {
            throw AESCTRError.invalidKeySize
        }

        switch mac {
        case "hmac-sha1":
            self.mac = .sha1
        case "hmac-sha1-96":
            self.mac = .sha1_96
        case "hmac-sha2-256":
            self.mac = .sha256
        case "hmac-sha2-512":
            self.mac = .sha512
        default:
            throw AESCTRError.invalidMac
        }

        self.keys = initialKeys
        self.encryptionContext = CCryptoBoringSSL_EVP_CIPHER_CTX_new()
        self.decryptionContext = CCryptoBoringSSL_EVP_CIPHER_CTX_new()

        let outboundEncryptionKey = Self.keyBytes(initialKeys.outboundEncryptionKey, size: keySizes.encryptionKeySize)
        let inboundEncryptionKey = Self.keyBytes(initialKeys.inboundEncryptionKey, size: keySizes.encryptionKeySize)

        guard CCryptoBoringSSL_EVP_CipherInit(
            encryptionContext,
            Self.evpCipher(),
            outboundEncryptionKey,
            initialKeys.initialOutboundIV,
            1
        ) == 1 else {
            throw AESCTRError.cryptographicError
        }
        guard CCryptoBoringSSL_EVP_CipherInit(
            decryptionContext,
            Self.evpCipher(),
            inboundEncryptionKey,
            initialKeys.initialInboundIV,
            0
        ) == 1 else {
            throw AESCTRError.cryptographicError
        }
    }

    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        let keySizes = try Self.keySizes(forMac: macName)
        guard
            newKeys.outboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8,
            newKeys.inboundEncryptionKey.bitCount == keySizes.encryptionKeySize * 8
        else {
            throw AESCTRError.invalidKeySize
        }

        self.keys = newKeys
        let outboundEncryptionKey = Self.keyBytes(newKeys.outboundEncryptionKey, size: keySizes.encryptionKeySize)
        let inboundEncryptionKey = Self.keyBytes(newKeys.inboundEncryptionKey, size: keySizes.encryptionKeySize)

        guard CCryptoBoringSSL_EVP_CipherInit(
            encryptionContext,
            Self.evpCipher(),
            outboundEncryptionKey,
            newKeys.initialOutboundIV,
            1
        ) == 1 else {
            throw AESCTRError.cryptographicError
        }
        guard CCryptoBoringSSL_EVP_CipherInit(
            decryptionContext,
            Self.evpCipher(),
            inboundEncryptionKey,
            newKeys.initialInboundIV,
            0
        ) == 1 else {
            throw AESCTRError.cryptographicError
        }
    }

    public func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        guard source.readableBytes >= Self.cipherBlockSize else {
            throw AESCTRError.invalidEncryptedPacketLength
        }

        try source.readWithUnsafeMutableReadableBytes { source in
            let source = source.bindMemory(to: UInt8.self)
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.cipherBlockSize)
            defer { out.deallocate() }

            guard CCryptoBoringSSL_EVP_Cipher(
                decryptionContext,
                out,
                source.baseAddress!,
                Self.cipherBlockSize
            ) == 1 else {
                throw AESCTRError.cryptographicError
            }
            memcpy(source.baseAddress!, out, Self.cipherBlockSize)
            return 0
        }
    }

    public func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        switch mac {
        case .sha1:
            return try _decryptAndVerifyRemainingPacket(&source, hash: Insecure.SHA1.self, sequenceNumber: sequenceNumber)
        case .sha1_96:
            return try _decryptAndVerifyRemainingPacket(&source, hash: Insecure.SHA1.self, sequenceNumber: sequenceNumber)
        case .sha256:
            return try _decryptAndVerifyRemainingPacket(&source, hash: SHA256.self, sequenceNumber: sequenceNumber)
        case .sha512:
            return try _decryptAndVerifyRemainingPacket(&source, hash: SHA512.self, sequenceNumber: sequenceNumber)
        }
    }

    public func encryptPacket(
        _ packet: NIOSSHEncryptablePayload,
        to outboundBuffer: inout ByteBuffer,
        sequenceNumber: UInt32
    ) throws {
        switch mac {
        case .sha1, .sha1_96:
            try _encryptPacket(packet, to: &outboundBuffer, hash: Insecure.SHA1.self, sequenceNumber: sequenceNumber)
        case .sha256:
            try _encryptPacket(packet, to: &outboundBuffer, hash: SHA256.self, sequenceNumber: sequenceNumber)
        case .sha512:
            try _encryptPacket(packet, to: &outboundBuffer, hash: SHA512.self, sequenceNumber: sequenceNumber)
        }
    }

    deinit {
        CCryptoBoringSSL_EVP_CIPHER_CTX_free(encryptionContext)
        CCryptoBoringSSL_EVP_CIPHER_CTX_free(decryptionContext)
    }

    // MARK: - Private

    private var macName: String {
        switch mac {
        case .sha1: "hmac-sha1"
        case .sha1_96: "hmac-sha1-96"
        case .sha256: "hmac-sha2-256"
        case .sha512: "hmac-sha2-512"
        }
    }

    private static func evpCipher() -> OpaquePointer {
        switch cipherKeySize {
        case 16: CCryptoBoringSSL_EVP_aes_128_ctr()
        case 24: CCryptoBoringSSL_EVP_aes_192_ctr()
        case 32: CCryptoBoringSSL_EVP_aes_256_ctr()
        default: preconditionFailure("Invalid AES key size \(cipherKeySize)")
        }
    }

    private static func keyBytes(_ key: SymmetricKey, size: Int) -> [UInt8] {
        key.withUnsafeBytes { buffer -> [UInt8] in
            let bytes = Array(buffer.bindMemory(to: UInt8.self))
            assert(bytes.count == size)
            return bytes
        }
    }

    private func _decryptAndVerifyRemainingPacket<H: HashFunction>(
        _ source: inout ByteBuffer,
        hash: H.Type,
        sequenceNumber: UInt32
    ) throws -> ByteBuffer {
        let macBytes = self.macBytes
        guard
            var plaintext = source.readBytes(length: Self.cipherBlockSize),
            let ciphertext = source.readBytes(length: source.readableBytes - macBytes),
            let macHash = source.readBytes(length: macBytes),
            ciphertext.count % Self.cipherBlockSize == 0
        else {
            throw AESCTRError.invalidEncryptedPacketLength
        }

        if !ciphertext.isEmpty {
            plaintext += try ciphertext.withUnsafeBufferPointer { ciphertext -> [UInt8] in
                let ciphertextPointer = ciphertext.baseAddress!
                return try [UInt8](
                    unsafeUninitializedCapacity: ciphertext.count,
                    initializingWith: { plaintext, count in
                        let plaintextPointer = plaintext.baseAddress!
                        while count < ciphertext.count {
                            guard CCryptoBoringSSL_EVP_Cipher(
                                decryptionContext,
                                plaintextPointer + count,
                                ciphertextPointer + count,
                                Self.cipherBlockSize
                            ) == 1 else {
                                throw AESCTRError.cryptographicError
                            }
                            count += Self.cipherBlockSize
                        }
                    }
                )
            }

            guard plaintext.count % Self.cipherBlockSize == 0 else {
                throw AESCTRError.invalidDecryptedPlaintextLength
            }
        }

        func expectedMAC() -> [UInt8] {
            var hmac = Crypto.HMAC<H>(key: keys.inboundMACKey)
            withUnsafeBytes(of: sequenceNumber.bigEndian) { buffer in
                hmac.update(data: buffer)
            }
            hmac.update(data: plaintext)
            let digest = hmac.finalize().withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
            return Array(digest.prefix(macBytes))
        }

        guard expectedMAC() == macHash else {
            throw AESCTRError.invalidMac
        }

        plaintext.removeFirst(4)
        let paddingLength = Int(plaintext.removeFirst())
        guard paddingLength < plaintext.count else {
            throw AESCTRError.invalidDecryptedPlaintextLength
        }
        plaintext.removeLast(paddingLength)
        return ByteBuffer(bytes: plaintext)
    }

    private func _encryptPacket<H: HashFunction>(
        _ packet: NIOSSHEncryptablePayload,
        to outboundBuffer: inout ByteBuffer,
        hash: H.Type,
        sequenceNumber: UInt32
    ) throws {
        let packetLengthIndex = outboundBuffer.writerIndex
        let packetLengthLength = MemoryLayout<UInt32>.size
        let packetPaddingIndex = outboundBuffer.writerIndex + packetLengthLength
        let packetPaddingLength = MemoryLayout<UInt8>.size

        outboundBuffer.moveWriterIndex(forwardBy: packetLengthLength + packetPaddingLength)
        let payloadBytes = outboundBuffer.writeEncryptablePayload(packet)

        let headerLength = packetLengthLength + packetPaddingLength
        let writtenBytes = headerLength + payloadBytes
        var paddingLength = Self.cipherBlockSize - (writtenBytes % Self.cipherBlockSize)
        if paddingLength < 4 {
            paddingLength += Self.cipherBlockSize
        }
        if headerLength + payloadBytes + paddingLength < Self.cipherBlockSize {
            paddingLength = Self.cipherBlockSize - headerLength - payloadBytes
        }

        let encryptedBufferSize = writtenBytes + outboundBuffer.writeSSHPaddingBytes(count: paddingLength)
        precondition(encryptedBufferSize % Self.cipherBlockSize == 0)

        outboundBuffer.setInteger(UInt32(encryptedBufferSize - packetLengthLength), at: packetLengthIndex)
        outboundBuffer.setInteger(UInt8(paddingLength), at: packetPaddingIndex)

        let plaintext = outboundBuffer.getBytes(at: packetLengthIndex, length: encryptedBufferSize)!
        assert(plaintext.count % Self.cipherBlockSize == 0)

        var hmac = Crypto.HMAC<H>(key: keys.outboundMACKey)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { buffer in
            hmac.update(data: buffer)
        }
        hmac.update(data: plaintext)
        let macHash = hmac.finalize().withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }

        let ciphertext = try plaintext.withUnsafeBufferPointer { plaintext -> [UInt8] in
            let plaintextPointer = plaintext.baseAddress!
            return try [UInt8](unsafeUninitializedCapacity: plaintext.count) { ciphertext, count in
                let ciphertextPointer = ciphertext.baseAddress!
                while count < encryptedBufferSize {
                    guard CCryptoBoringSSL_EVP_Cipher(
                        encryptionContext,
                        ciphertextPointer + count,
                        plaintextPointer + count,
                        Self.cipherBlockSize
                    ) == 1 else {
                        throw AESCTRError.cryptographicError
                    }
                    count += Self.cipherBlockSize
                }
            }
        }

        outboundBuffer.setBytes(ciphertext, at: packetLengthIndex)
        outboundBuffer.writeBytes(macHash.prefix(macBytes))
    }
}

public final class AES128CTRTransportProtection: AESCTRTransportProtection {
    public override class var cipherName: String { "aes128-ctr" }
    public override class var cipherKeySize: Int { 16 }
}

public final class AES192CTRTransportProtection: AESCTRTransportProtection {
    public override class var cipherName: String { "aes192-ctr" }
    public override class var cipherKeySize: Int { 24 }
}

public final class AES256CTRTransportProtection: AESCTRTransportProtection {
    public override class var cipherName: String { "aes256-ctr" }
    public override class var cipherKeySize: Int { 32 }
}
