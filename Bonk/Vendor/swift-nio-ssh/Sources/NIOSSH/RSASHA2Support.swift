// swiftlint:disable comment_spacing
//===----------------------------------------------------------------------===//
//
//  RSASHA2Support.swift
//  NIOSSH
//
//  RFC 8332 rsa-sha2-256 / rsa-sha2-512 support for verifying server host
//  keys. The wire blob keeps the legacy "ssh-rsa" identifier, while the
//  negotiated host-key algorithm decides the digest.
//
//===----------------------------------------------------------------------===//
// swiftlint:enable comment_spacing

import Crypto
import _CryptoExtras
import Foundation
import NIO
import NIOFoundationCompat

public enum RSASHA2Error: Error {
    case invalidFormat
}

/// Signature for rsa-sha2-256 / rsa-sha2-512.
open class RSASHA2SignatureBase: NIOSSHSignatureProtocol {
    open class var signaturePrefix: String { "rsa-sha2-256" }

    public let rawRepresentation: Data

    public required init(rawRepresentation: Data) {
        self.rawRepresentation = rawRepresentation
    }

    public func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(rawRepresentation)
    }

    public static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let payload = buffer.readSSHString(),
              let data = payload.getData(at: payload.readerIndex, length: payload.readableBytes)
        else {
            throw RSASHA2Error.invalidFormat
        }
        return Self(rawRepresentation: data)
    }
}

public class RSASHA2Signature256: RSASHA2SignatureBase {
    public override class var signaturePrefix: String { "rsa-sha2-256" }
}

public class RSASHA2Signature512: RSASHA2SignatureBase {
    public override class var signaturePrefix: String { "rsa-sha2-512" }
}

/// Public key verifying RSA signatures with the digest chosen by the
/// signature's algorithm identifier (ssh-rsa / rsa-sha2-256 / rsa-sha2-512).
open class RSASHA2PublicKeyBase: NIOSSHPublicKeyProtocol {
    open class var publicKeyPrefix: String { "rsa-sha2-256" }

    internal let rsaKey: _RSA.Signing.PublicKey
    internal let publicExponentData: Data
    internal let modulusData: Data

    public var rawRepresentation: Data {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = write(to: &buffer)
        return buffer.readData(length: buffer.readableBytes) ?? Data()
    }

    public required init(publicExponent: Data, modulus: Data) throws {
        let key = try _RSA.Signing.PublicKey(n: modulus, e: publicExponent)
        let primitives = try key.getKeyPrimitives()
        self.rsaKey = key
        self.publicExponentData = primitives.publicExponent
        self.modulusData = primitives.modulus
    }

    public func write(to buffer: inout ByteBuffer) -> Int {
        var written = 0
        written += buffer.writePositiveMPInt(publicExponentData)
        written += buffer.writePositiveMPInt(modulusData)
        return written
    }

    public static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let eBuffer = buffer.readSSHString(),
              let nBuffer = buffer.readSSHString(),
              let eBytes = eBuffer.getData(at: eBuffer.readerIndex, length: eBuffer.readableBytes),
              let nBytes = nBuffer.getData(at: nBuffer.readerIndex, length: nBuffer.readableBytes)
        else {
            throw RSASHA2Error.invalidFormat
        }
        return try Self(publicExponent: eBytes, modulus: nBytes)
    }

    public func isValidSignature<D: DataProtocol>(
        _ signature: NIOSSHSignatureProtocol,
        for data: D
    ) -> Bool {
        let rsaSignature = _RSA.Signing.RSASignature(rawRepresentation: signature.rawRepresentation)
        let dataBytes = Array(data)
        let result: Bool
        switch signature.signaturePrefix {
        case "rsa-sha2-256":
            result = rsaKey.isValidSignature(
                rsaSignature,
                for: SHA256.hash(data: dataBytes),
                padding: .insecurePKCS1v1_5
            )
        case "rsa-sha2-512":
            result = rsaKey.isValidSignature(
                rsaSignature,
                for: SHA512.hash(data: dataBytes),
                padding: .insecurePKCS1v1_5
            )
        case "ssh-rsa":
            result = rsaKey.isValidSignature(
                rsaSignature,
                for: Insecure.SHA1.hash(data: dataBytes),
                padding: .insecurePKCS1v1_5
            )
        default:
            return false
        }
        return result
    }
}

public class RSASHA2PublicKey256: RSASHA2PublicKeyBase {
    public override class var publicKeyPrefix: String { "rsa-sha2-256" }
}

public class RSASHA2PublicKey512: RSASHA2PublicKeyBase {
    public override class var publicKeyPrefix: String { "rsa-sha2-512" }
}

/// Registers the RFC 8332 algorithms. Idempotent; call once at startup.
public enum RSASHA2Support {
    private static let registeredOnce: Void = {
        NIOSSHAlgorithms.register(
            publicKey: RSASHA2PublicKey256.self,
            signature: RSASHA2Signature256.self
        )
        NIOSSHAlgorithms.register(
            publicKey: RSASHA2PublicKey512.self,
            signature: RSASHA2Signature512.self
        )
    }()

    public static func register() {
        _ = registeredOnce
    }
}
