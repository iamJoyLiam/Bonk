//
//  SSHHostKeyValidatorTests.swift
//  BonkTests — regression lock for the P0 trust-ordering invariant:
//
//  host-key mismatch → validation promise fails → handshake aborts
//  BEFORE any authentication material is transmitted.
//
//  Uses EmbeddedEventLoop: no live server required.

import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

@testable import Bonk

final class SSHHostKeyValidatorTests: XCTestCase {
    private func makePresentedKey() -> NIOSSHPublicKey {
        NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
    }

    private func fingerprint(of key: NIOSSHPublicKey) -> SSHHostFingerprint {
        var buffer = ByteBuffer()
        key.write(to: &buffer)
        let bytes = Data(buffer.readableBytesView)
        let digest = SHA256.hash(data: bytes)
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return SSHHostFingerprint(hash: "SHA256:\(b64)")
    }

    /// Core P0 assertion: on mismatch the promise fails AND no fingerprint
    /// is recorded, so no caller can proceed to authentication.
    func testMismatchFailsPromiseAndRecordsNothing() throws {
        let loop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try loop.syncShutdownGracefully()) }
        let presented = makePresentedKey()
        // Bogus expected: guaranteed mismatch regardless of hash algorithm.
        let expected = SSHHostFingerprint(hash: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let recordedBox = NIOLockedValueBox<SSHHostFingerprint?>(nil)
        let validator = HostKeyValidator(expected: expected) { fp in
            recordedBox.withLockedValue { $0 = fp }
        }

        let promise = loop.makePromise(of: Void.self)
        validator.validateHostKey(hostKey: presented, validationCompletePromise: promise)

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            guard let svc = error as? SSHServiceError,
                  case let .hostKeyMismatch(exp, got) = svc
            else {
                XCTFail("expected hostKeyMismatch, got \(error)")
                return
            }
            XCTAssertEqual(exp, expected.hash)
            XCTAssertTrue(got.hasPrefix("SHA256:"))
            XCTAssertNotEqual(got, exp)
        }
        XCTAssertNil(
            recordedBox.withLockedValue { $0 },
            "mismatched key must never be recorded for later auth"
        )
    }

    func testMatchSucceedsAndRecords() throws {
        let loop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try loop.syncShutdownGracefully()) }
        let presented = makePresentedKey()
        let expected = fingerprint(of: presented)
        let recordedBox = NIOLockedValueBox<SSHHostFingerprint?>(nil)
        let validator = HostKeyValidator(expected: expected) { fp in
            recordedBox.withLockedValue { $0 = fp }
        }

        let promise = loop.makePromise(of: Void.self)
        validator.validateHostKey(hostKey: presented, validationCompletePromise: promise)

        XCTAssertNoThrow(try promise.futureResult.wait())
        XCTAssertEqual(recordedBox.withLockedValue { $0?.hash }, expected.hash)
    }

    /// TOFU first-seen (no known fingerprint) must still connect.
    func testFirstSeenNilExpectedSucceedsAndRecords() throws {
        let loop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try loop.syncShutdownGracefully()) }
        let presented = makePresentedKey()
        let recordedBox = NIOLockedValueBox<SSHHostFingerprint?>(nil)
        let validator = HostKeyValidator(expected: nil) { fp in
            recordedBox.withLockedValue { $0 = fp }
        }

        let promise = loop.makePromise(of: Void.self)
        validator.validateHostKey(hostKey: presented, validationCompletePromise: promise)

        XCTAssertNoThrow(try promise.futureResult.wait())
        XCTAssertEqual(
            recordedBox.withLockedValue { $0?.hash },
            fingerprint(of: presented).hash
        )
    }
}
