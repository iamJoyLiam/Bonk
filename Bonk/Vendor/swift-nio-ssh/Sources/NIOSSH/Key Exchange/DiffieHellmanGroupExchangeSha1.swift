// swiftlint:disable comment_spacing
//===----------------------------------------------------------------------===//
//
//  DiffieHellmanGroupExchangeSha1.swift
//  NIOSSH
//
//  RFC 4419 diffie-hellman-group-exchange-sha1 (client side).
//  Server sends p/g after the client's request; the client replies with e and
//  finalizes on the reply. Multi-round-trip, so it opts into the GEX hooks.
//
//===----------------------------------------------------------------------===//
// swiftlint:enable comment_spacing
// swiftlint:disable identifier_name

import CCryptoBoringSSL
import Crypto
import Foundation
import NIO

public struct DiffieHellmanGroupExchangeSha1: NIOSSHKeyExchangeAlgorithmProtocol {
    public static let keyExchangeInitMessageId: UInt8 = 30
    public static let keyExchangeReplyMessageId: UInt8 = 33

    public static let keyExchangeAlgorithmNames: [Substring] = [
        "diffie-hellman-group-exchange-sha1",
    ]

    public var supportsGEX: Bool { true }

    private var ourRole: SSHConnectionRole
    private var previousSessionIdentifier: ByteBuffer?
    private var privateExponent: UnsafeMutablePointer<BIGNUM>?
    private var groupPrime: UnsafeMutablePointer<BIGNUM>?
    private var generator: UnsafeMutablePointer<BIGNUM>?
    private var ourPublicKeyData: Data?
    private var minBits: UInt32 = 1024
    private var nBits: UInt32 = 2048
    private var maxBits: UInt32 = 8192

    public init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier
    }

    // MARK: - Client flow

    public func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) -> ByteBuffer {
        // OpenSSH parses min + n + max for both request ids, so send all three.
        var buffer = allocator.buffer(capacity: 12)
        buffer.writeInteger(minBits)
        buffer.writeInteger(nBits)
        buffer.writeInteger(maxBits)
        return buffer
    }

    public mutating func receiveGEXGroup(
        p: ByteBuffer,
        g: ByteBuffer,
        allocator _: ByteBufferAllocator,
        expectedKeySizes _: ExpectedKeySizes
    ) throws -> ByteBuffer {
        guard ourRole.isClient else {
            throw DiffieHellmanGEXSHA1Error.serverOnly
        }

        let pBytes = p.getBytes(at: p.readerIndex, length: p.readableBytes) ?? []
        let gBytes = g.getBytes(at: g.readerIndex, length: g.readableBytes) ?? []
        guard let prime = CCryptoBoringSSL_BN_bin2bn(pBytes, pBytes.count, nil),
              let generator = CCryptoBoringSSL_BN_bin2bn(gBytes, gBytes.count, nil)
        else {
            throw DiffieHellmanGEXSHA1Error.invalidGroup
        }
        groupPrime = prime
        self.generator = generator

        let exponent = CCryptoBoringSSL_BN_new()!
        // 256-bit private exponent is plenty for a 2048-bit safe-prime group.
        CCryptoBoringSSL_BN_rand(exponent, 256, 0, 0)
        privateExponent = exponent

        let publicKey = CCryptoBoringSSL_BN_new()!
        let ctx = CCryptoBoringSSL_BN_CTX_new()!
        defer { CCryptoBoringSSL_BN_CTX_free(ctx) }
        guard CCryptoBoringSSL_BN_mod_exp(publicKey, generator, exponent, prime, ctx) == 1 else {
            throw DiffieHellmanGEXSHA1Error.modExpFailed
        }
        var out = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_BN_num_bytes(publicKey)))
        CCryptoBoringSSL_BN_bn2bin(publicKey, &out)
        CCryptoBoringSSL_BN_free(publicKey)
        ourPublicKeyData = Data(out)

        // GEX_INIT carries e as an mpint string; add the sign byte when the
        // high bit is set or the server reads it as a negative bignum.
        var payload = Data()
        if let first = out.first, first & 0x80 != 0 {
            payload.append(0)
        }
        payload.append(contentsOf: out)
        var buffer = ByteBufferAllocator().buffer(capacity: payload.count + 8)
        buffer.writeBytes(payload)
        return buffer
    }

    public mutating func receiveGEXReply(
        serverKeyExchangeMessage: NIOSSHKeyExchangeServerReply,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> KeyExchangeResult {
        guard ourRole.isClient, let privateExponent else {
            throw DiffieHellmanGEXSHA1Error.invalidState
        }

        let fBytes = serverKeyExchangeMessage.publicKey.getBytes(
            at: serverKeyExchangeMessage.publicKey.readerIndex,
            length: serverKeyExchangeMessage.publicKey.readableBytes
        ) ?? []
        guard let serverPublicKey = CCryptoBoringSSL_BN_bin2bn(fBytes, fBytes.count, nil),
              let groupPrime,
              let generator
        else {
            throw DiffieHellmanGEXSHA1Error.invalidState
        }
        defer { CCryptoBoringSSL_BN_free(serverPublicKey) }

        let secret = CCryptoBoringSSL_BN_new()!
        defer { CCryptoBoringSSL_BN_free(secret) }
        let ctx = CCryptoBoringSSL_BN_CTX_new()!
        defer { CCryptoBoringSSL_BN_CTX_free(ctx) }
        guard CCryptoBoringSSL_BN_mod_exp(secret, serverPublicKey, privateExponent, groupPrime, ctx) == 1 else {
            throw DiffieHellmanGEXSHA1Error.modExpFailed
        }

        var secretBytes = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_BN_num_bytes(secret)))
        CCryptoBoringSSL_BN_bn2bin(secret, &secretBytes)

        // H = SHA256(V_C || V_S || I_C || I_S || K_S || min || n || max || p || g || e || f || K)
        initialExchangeBytes.writeCompositeSSHString {
            $0.writeSSHHostKey(serverKeyExchangeMessage.hostKey)
        }
        initialExchangeBytes.writeInteger(minBits)
        initialExchangeBytes.writeInteger(nBits)
        initialExchangeBytes.writeInteger(maxBits)
        initialExchangeBytes.writePositiveMPInt(pBytes())
        initialExchangeBytes.writePositiveMPInt(gBytes())
        if let ourPublicKeyData {
            initialExchangeBytes.writePositiveMPInt(ourPublicKeyData)
        }
        initialExchangeBytes.writePositiveMPInt(fBytes)
        initialExchangeBytes.writePositiveMPInt(secretBytes)

        let exchangeHash = Insecure.SHA1.hash(data: initialExchangeBytes.readableBytesView)

        let sessionID: ByteBuffer
        if let previousSessionIdentifier {
            sessionID = previousSessionIdentifier
        } else {
            var hashBytes = allocator.buffer(capacity: Insecure.SHA1.byteCount)
            hashBytes.writeContiguousBytes(exchangeHash)
            sessionID = hashBytes
        }

        let keys = Self.generateKeys(
            secretBytes: secretBytes,
            exchangeHash: exchangeHash,
            sessionID: sessionID,
            expectedKeySizes: expectedKeySizes,
            role: ourRole
        )

        guard serverKeyExchangeMessage.hostKey.isValidSignature(
            serverKeyExchangeMessage.signature,
            for: exchangeHash
        ) else {
            throw DiffieHellmanGEXSHA1Error.invalidSignature
        }

        return KeyExchangeResult(sessionID: sessionID, keys: keys)
    }

    private func pBytes() -> [UInt8] {
        guard let groupPrime else { return [] }
        var out = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_BN_num_bytes(groupPrime)))
        CCryptoBoringSSL_BN_bn2bin(groupPrime, &out)
        return out
    }

    private func gBytes() -> [UInt8] {
        guard let generator else { return [] }
        var out = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_BN_num_bytes(generator)))
        CCryptoBoringSSL_BN_bn2bin(generator, &out)
        return out
    }

    // MARK: - Server side (unsupported — Bonk is a client)

    public mutating func completeKeyExchangeServerSide(
        clientKeyExchangeMessage _: ByteBuffer,
        serverHostKey _: NIOSSHPrivateKey,
        initialExchangeBytes _: inout ByteBuffer,
        allocator _: ByteBufferAllocator,
        expectedKeySizes _: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, NIOSSHKeyExchangeServerReply) {
        throw DiffieHellmanGEXSHA1Error.serverOnly
    }

    // MARK: - Key derivation

    private static func generateKeys(
        secretBytes: [UInt8],
        exchangeHash: Insecure.SHA1.Digest,
        sessionID: ByteBuffer,
        expectedKeySizes: ExpectedKeySizes,
        role: SSHConnectionRole
    ) -> NIOSSHSessionKeys {
        func key(letter: UInt8, expectedKeySize size: Int) -> [UInt8] {
            var result = [UInt8]()
            var hashInput = ByteBuffer()

            while result.count < size {
                hashInput.moveWriterIndex(to: 0)
                hashInput.writePositiveMPInt(secretBytes)
                hashInput.writeBytes(exchangeHash)

                if !result.isEmpty {
                    hashInput.writeBytes(result)
                } else {
                    hashInput.writeInteger(letter)
                    hashInput.writeBytes(sessionID.readableBytesView)
                }

                result += Insecure.SHA1.hash(data: hashInput.readableBytesView)
            }

            result.removeLast(result.count - size)
            return result
        }

        func symmetricKey(letter: UInt8, expectedKeySize size: Int) -> SymmetricKey {
            SymmetricKey(data: key(letter: letter, expectedKeySize: size))
        }

        switch role {
        case .client:
            return NIOSSHSessionKeys(
                initialInboundIV: key(letter: UInt8(ascii: "B"), expectedKeySize: expectedKeySizes.ivSize),
                initialOutboundIV: key(letter: UInt8(ascii: "A"), expectedKeySize: expectedKeySizes.ivSize),
                inboundEncryptionKey: symmetricKey(
                    letter: UInt8(ascii: "D"), expectedKeySize: expectedKeySizes.encryptionKeySize
                ),
                outboundEncryptionKey: symmetricKey(
                    letter: UInt8(ascii: "C"), expectedKeySize: expectedKeySizes.encryptionKeySize
                ),
                inboundMACKey: symmetricKey(
                    letter: UInt8(ascii: "F"), expectedKeySize: expectedKeySizes.macKeySize
                ),
                outboundMACKey: symmetricKey(
                    letter: UInt8(ascii: "E"), expectedKeySize: expectedKeySizes.macKeySize
                )
            )
        case .server:
            return NIOSSHSessionKeys(
                initialInboundIV: key(letter: UInt8(ascii: "A"), expectedKeySize: expectedKeySizes.ivSize),
                initialOutboundIV: key(letter: UInt8(ascii: "B"), expectedKeySize: expectedKeySizes.ivSize),
                inboundEncryptionKey: symmetricKey(
                    letter: UInt8(ascii: "C"), expectedKeySize: expectedKeySizes.encryptionKeySize
                ),
                outboundEncryptionKey: symmetricKey(
                    letter: UInt8(ascii: "D"), expectedKeySize: expectedKeySizes.encryptionKeySize
                ),
                inboundMACKey: symmetricKey(
                    letter: UInt8(ascii: "E"), expectedKeySize: expectedKeySizes.macKeySize
                ),
                outboundMACKey: symmetricKey(
                    letter: UInt8(ascii: "F"), expectedKeySize: expectedKeySizes.macKeySize
                )
            )
        }
    }
}

enum DiffieHellmanGEXSHA1Error: Error {
    case invalidGroup
    case modExpFailed
    case invalidState
    case invalidSignature
    case serverOnly
}
// swiftlint:enable identifier_name
