//===----------------------------------------------------------------------===//
//
//  DiffieHellmanFixedGroup.swift
//  NIOSSH
//
//  Fixed MODP group key exchange for legacy/enterprise SSH servers:
//  diffie-hellman-group1-sha1 (RFC 2409), group16-sha512 and
//  group18-sha512 (RFC 3526). Client side only.
//
//===----------------------------------------------------------------------===//
// swiftlint:disable identifier_name

import CCryptoBoringSSL
import Crypto
import Foundation
import NIO

enum DiffieHellmanFixedGroupError: Error {
    case invalidState
    case modExpFailed
    case invalidSignature
    case serverOnly
}

/// Static parameters for a fixed MODP group.
public protocol DiffieHellmanGroupParameters {
    static var name: String { get }
    static var primeHex: String { get }
    static var hashByteCount: Int { get }
    static func hash<D: DataProtocol>(_ data: D) -> Data
}

public enum DiffieHellmanGroup1SHA1Parameters: DiffieHellmanGroupParameters {
    public static let name = "diffie-hellman-group1-sha1"
    public static let primeHex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF"
    public static var hashByteCount: Int { Insecure.SHA1.byteCount }
    public static func hash<D: DataProtocol>(_ data: D) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }
}

public enum DiffieHellmanGroup16SHA512Parameters: DiffieHellmanGroupParameters {
    public static let name = "diffie-hellman-group16-sha512"
    public static let primeHex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D788719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA993B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF"
    public static var hashByteCount: Int { SHA512.byteCount }
    public static func hash<D: DataProtocol>(_ data: D) -> Data {
        Data(SHA512.hash(data: data))
    }
}

public enum DiffieHellmanGroup18SHA512Parameters: DiffieHellmanGroupParameters {
    public static let name = "diffie-hellman-group18-sha512"
    public static let primeHex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D788719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA993B4EA988D8FDDC186FFB7DC90A6C08F4DF435C93402849236C3FAB4D27C7026C1D4DCB2602646DEC9751E763DBA37BDF8FF9406AD9E530EE5DB382F413001AEB06A53ED9027D831179727B0865A8918DA3EDBEBCF9B14ED44CE6CBACED4BB1BDB7F1447E6CC254B332051512BD7AF426FB8F401378CD2BF5983CA01C64B92ECF032EA15D1721D03F482D7CE6E74FEF6D55E702F46980C82B5A84031900B1C9E59E7C97FBEC7E8F323A97A7E36CC88BE0F1D45B7FF585AC54BD407B22B4154AACC8F6D7EBF48E1D814CC5ED20F8037E0A79715EEF29BE32806A1D58BB7C5DA76F550AA3D8A1FBFF0EB19CCB1A313D55CDA56C9EC2EF29632387FE8D76E3C0468043E8F663F4860EE12BF2D5B0B7474D6E694F91E6DBE115974A3926F12FEE5E438777CB6A932DF8CD8BEC4D073B931BA3BC832B68D9DD300741FA7BF8AFC47ED2576F6936BA424663AAB639C5AE4F5683423B4742BF1C978238F16CBE39D652DE3FDB8BEFC848AD922222E04A4037C0713EB57A81A23F0C73473FC646CEA306B4BCBC8862F8385DDFA9D4B7FA2C087E879683303ED5BDD3A062B3CF5B3A278A66D2A13F83F44F82DDF310EE074AB6A364597E899A0255DC164F31CC50846851DF9AB48195DED7EA1B1D510BD7EE74D73FAF36BC31ECFA268359046F4EB879F924009438B481C6CD7889A002ED5EE382BC9190DA6FC026E479558E4475677E9AA9E3050E2765694DFC81F56E880B96E7160C980DD98EDD3DFFFFFFFFFFFFFFFFF"
    public static var hashByteCount: Int { SHA512.byteCount }
    public static func hash<D: DataProtocol>(_ data: D) -> Data {
        Data(SHA512.hash(data: data))
    }
}

/// RFC 4253 fixed-group Diffie-Hellman key exchange (SSH_MSG_KEXDH_INIT/REPLY).
public struct DiffieHellmanFixedGroup<Parameters: DiffieHellmanGroupParameters>: NIOSSHKeyExchangeAlgorithmProtocol {
    public static var keyExchangeInitMessageId: UInt8 { 30 }
    public static var keyExchangeReplyMessageId: UInt8 { 31 }
    public static var keyExchangeAlgorithmNames: [Substring] { [Substring(Parameters.name)] }

    private var ourRole: SSHConnectionRole
    private var previousSessionIdentifier: ByteBuffer?
    private var privateExponent: UnsafeMutablePointer<BIGNUM>?
    private var ourPublicKeyData: Data?

    public init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier

        if ourRole.isClient {
            let values = Self.generateClientValues()
            self.privateExponent = values.exponent
            self.ourPublicKeyData = values.publicKey
        }
    }

    public func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) -> ByteBuffer {
        guard let ourPublicKeyData else { return allocator.buffer(capacity: 0) }

        // e is an mpint; add a sign byte when the high bit is set.
        var payload = Data()
        if let first = ourPublicKeyData.first, first & 0x80 != 0 {
            payload.append(0)
        }
        payload.append(contentsOf: ourPublicKeyData)

        var buffer = allocator.buffer(capacity: payload.count + 8)
        buffer.writeBytes(payload)
        return buffer
    }

    public mutating func completeKeyExchangeServerSide(
        clientKeyExchangeMessage _: ByteBuffer,
        serverHostKey _: NIOSSHPrivateKey,
        initialExchangeBytes _: inout ByteBuffer,
        allocator _: ByteBufferAllocator,
        expectedKeySizes _: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, NIOSSHKeyExchangeServerReply) {
        throw DiffieHellmanFixedGroupError.serverOnly
    }

    public mutating func receiveServerKeyExchangePayload(
        serverKeyExchangeMessage: NIOSSHKeyExchangeServerReply,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> KeyExchangeResult {
        guard ourRole.isClient, let privateExponent, let ourPublicKeyData else {
            throw DiffieHellmanFixedGroupError.invalidState
        }

        let fBytes = serverKeyExchangeMessage.publicKey.getBytes(
            at: serverKeyExchangeMessage.publicKey.readerIndex,
            length: serverKeyExchangeMessage.publicKey.readableBytes
        ) ?? []
        guard let serverPublicKey = CCryptoBoringSSL_BN_bin2bn(fBytes, fBytes.count, nil) else {
            throw DiffieHellmanFixedGroupError.invalidState
        }
        defer { CCryptoBoringSSL_BN_free(serverPublicKey) }

        let primeBytes = Self.primeBytes()
        guard let groupPrime = CCryptoBoringSSL_BN_bin2bn(primeBytes, primeBytes.count, nil) else {
            throw DiffieHellmanFixedGroupError.invalidState
        }
        defer { CCryptoBoringSSL_BN_free(groupPrime) }

        let secret = CCryptoBoringSSL_BN_new()!
        defer { CCryptoBoringSSL_BN_free(secret) }
        let ctx = CCryptoBoringSSL_BN_CTX_new()!
        defer { CCryptoBoringSSL_BN_CTX_free(ctx) }
        guard CCryptoBoringSSL_BN_mod_exp(secret, serverPublicKey, privateExponent, groupPrime, ctx) == 1 else {
            throw DiffieHellmanFixedGroupError.modExpFailed
        }

        var secretBytes = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_BN_num_bytes(secret)))
        CCryptoBoringSSL_BN_bn2bin(secret, &secretBytes)

        // H = hash(V_C || V_S || I_C || I_S || K_S || e || f || K)
        initialExchangeBytes.writeCompositeSSHString {
            $0.writeSSHHostKey(serverKeyExchangeMessage.hostKey)
        }
        initialExchangeBytes.writePositiveMPInt(ourPublicKeyData)
        initialExchangeBytes.writePositiveMPInt(fBytes)
        initialExchangeBytes.writePositiveMPInt(secretBytes)

        let exchangeHash = Parameters.hash(initialExchangeBytes.readableBytesView)

        let sessionID: ByteBuffer
        if let previousSessionIdentifier {
            sessionID = previousSessionIdentifier
        } else {
            var hashBytes = allocator.buffer(capacity: Parameters.hashByteCount)
            hashBytes.writeBytes(exchangeHash)
            sessionID = hashBytes
        }

        let keys = Self.generateKeys(
            secretBytes: secretBytes,
            exchangeHash: exchangeHash,
            sessionID: sessionID,
            expectedKeySizes: expectedKeySizes,
            role: ourRole
        )

        var hashBuffer = allocator.buffer(capacity: Parameters.hashByteCount)
        hashBuffer.writeBytes(exchangeHash)
        guard serverKeyExchangeMessage.hostKey.isValidSignature(
            serverKeyExchangeMessage.signature,
            for: hashBuffer
        ) else {
            throw DiffieHellmanFixedGroupError.invalidSignature
        }

        return KeyExchangeResult(sessionID: sessionID, keys: keys)
    }

    // MARK: - Private

    private static func generateClientValues() -> (exponent: UnsafeMutablePointer<BIGNUM>, publicKey: Data) {
        let primeBytes = primeBytes()
        let prime = CCryptoBoringSSL_BN_bin2bn(primeBytes, primeBytes.count, nil)!
        let generator = CCryptoBoringSSL_BN_new()!
        CCryptoBoringSSL_BN_set_word(generator, 2)

        let exponent = CCryptoBoringSSL_BN_new()!
        // 256-bit private exponent is plenty for these safe-prime groups.
        CCryptoBoringSSL_BN_rand(exponent, 256, 0, 0)

        let publicKey = CCryptoBoringSSL_BN_new()!
        let ctx = CCryptoBoringSSL_BN_CTX_new()!
        defer {
            CCryptoBoringSSL_BN_free(prime)
            CCryptoBoringSSL_BN_free(generator)
            CCryptoBoringSSL_BN_CTX_free(ctx)
        }
        precondition(CCryptoBoringSSL_BN_mod_exp(publicKey, generator, exponent, prime, ctx) == 1)

        var out = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_BN_num_bytes(publicKey)))
        CCryptoBoringSSL_BN_bn2bin(publicKey, &out)
        CCryptoBoringSSL_BN_free(publicKey)
        return (exponent, Data(out))
    }

    private static func primeBytes() -> [UInt8] {
        let hex = Parameters.primeHex
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    private static func generateKeys(
        secretBytes: [UInt8],
        exchangeHash: Data,
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

                result += Parameters.hash(hashInput.readableBytesView)
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
                inboundEncryptionKey: symmetricKey(letter: UInt8(ascii: "D"), expectedKeySize: expectedKeySizes.encryptionKeySize),
                outboundEncryptionKey: symmetricKey(letter: UInt8(ascii: "C"), expectedKeySize: expectedKeySizes.encryptionKeySize),
                inboundMACKey: symmetricKey(letter: UInt8(ascii: "F"), expectedKeySize: expectedKeySizes.macKeySize),
                outboundMACKey: symmetricKey(letter: UInt8(ascii: "E"), expectedKeySize: expectedKeySizes.macKeySize)
            )
        case .server:
            return NIOSSHSessionKeys(
                initialInboundIV: key(letter: UInt8(ascii: "A"), expectedKeySize: expectedKeySizes.ivSize),
                initialOutboundIV: key(letter: UInt8(ascii: "B"), expectedKeySize: expectedKeySizes.ivSize),
                inboundEncryptionKey: symmetricKey(letter: UInt8(ascii: "C"), expectedKeySize: expectedKeySizes.encryptionKeySize),
                outboundEncryptionKey: symmetricKey(letter: UInt8(ascii: "D"), expectedKeySize: expectedKeySizes.encryptionKeySize),
                inboundMACKey: symmetricKey(letter: UInt8(ascii: "E"), expectedKeySize: expectedKeySizes.macKeySize),
                outboundMACKey: symmetricKey(letter: UInt8(ascii: "F"), expectedKeySize: expectedKeySizes.macKeySize)
            )
        }
    }
}
// swiftlint:enable identifier_name
