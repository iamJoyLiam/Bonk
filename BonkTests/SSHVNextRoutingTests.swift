import XCTest
@testable import Bonk

final class SSHVNextRoutingTests: XCTestCase {

    // MARK: - NativeErrorClassifier

    func testClassifierKEXFailureIsProtocolCompatibility() {
        let err = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "keyExchangeNegotiationFailure"])
        let ctx = SSHFailureContext(phase: .keyExchange, underlyingError: err)
        XCTAssertEqual(NativeErrorClassifier().classify(ctx), .protocolCompatibility)
    }

    func testClassifierNoMatchingKeyExchangeIsProtocolCompatibility() {
        let err = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no matching key exchange method found"])
        let ctx = SSHFailureContext(phase: .keyExchange, underlyingError: err)
        XCTAssertEqual(NativeErrorClassifier().classify(ctx), .protocolCompatibility)
    }

    func testClassifierHostKeyIdentityMismatchIsAuthentication() {
        let err = SSHServiceError.hostKeyMismatch(expected: "a", received: "b")
        let ctx = SSHFailureContext(phase: .hostKeyVerification, underlyingError: err)
        XCTAssertEqual(NativeErrorClassifier().classify(ctx), .authentication)
        XCTAssertFalse(NativeErrorClassifier().classify(ctx).canFallbackToCompatibility)
    }

    func testClassifierHostKeyAlgorithmUnsupportedIsCompatibility() {
        let err = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalidHostKeyForKeyExchange"])
        let ctx = SSHFailureContext(phase: .hostKeyVerification, underlyingError: err)
        XCTAssertEqual(NativeErrorClassifier().classify(ctx), .protocolCompatibility)
        XCTAssertTrue(NativeErrorClassifier().classify(ctx).canFallbackToCompatibility)
    }

    func testClassifierNoSupportedAuthIsBackendCapability() {
        let err = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no supported authentication methods available"])
        let ctx = SSHFailureContext(phase: .userAuthentication, underlyingError: err)
        XCTAssertEqual(NativeErrorClassifier().classify(ctx), .backendCapability)
        XCTAssertTrue(NativeErrorClassifier().classify(ctx).canFallbackToCompatibility)
    }

    func testClassifierPermissionDeniedIsAuthentication() {
        let err = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        let ctx = SSHFailureContext(phase: .userAuthentication, underlyingError: err)
        XCTAssertEqual(NativeErrorClassifier().classify(ctx), .authentication)
        XCTAssertFalse(NativeErrorClassifier().classify(ctx).canFallbackToCompatibility)
    }

    func testClassifierTransportNotFallback() {
        let err = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection refused"])
        let ctx = SSHFailureContext(phase: .tcp, underlyingError: err)
        XCTAssertEqual(NativeErrorClassifier().classify(ctx), .transport)
        XCTAssertFalse(NativeErrorClassifier().classify(ctx).canFallbackToCompatibility)
    }

    // MARK: - Coordinator resolve matrix

    func testCoordinatorCertGoesCompatibility() async {
        let coord = SSHSessionCoordinator()
        let req = SSHConnectionRequirements(authentication: .certificate, route: .direct, endpoint: SSHEndpoint(host: "h", port: 22))
        let dec = await coord.resolve(request: SSHConnectionRequest(requirements: req))
        guard case .compatibility = dec else { return XCTFail("expected compatibility") }
    }

    func testCoordinatorRSAKeyGoesCompatibility() async {
        let coord = SSHSessionCoordinator()
        let req = SSHConnectionRequirements(authentication: .publicKey, keyAlgorithm: .rsa, route: .direct, endpoint: SSHEndpoint(host: "h", port: 22))
        let dec = await coord.resolve(request: SSHConnectionRequest(requirements: req))
        guard case .compatibility = dec else { return XCTFail("rsa should be compatibility") }
    }

    func testCoordinatorKeyboardInteractiveGoesCompatibility() async {
        let coord = SSHSessionCoordinator()
        let req = SSHConnectionRequirements(authentication: .keyboardInteractive, route: .direct, endpoint: SSHEndpoint(host: "h", port: 22))
        let dec = await coord.resolve(request: SSHConnectionRequest(requirements: req))
        guard case .compatibility = dec else { return XCTFail() }
    }

    func testCoordinatorJumpHostGoesCompatibility() async {
        let coord = SSHSessionCoordinator()
        let route = SSHRoute(hops: [SSHEndpoint(host: "jump", port: 22)])
        let req = SSHConnectionRequirements(authentication: .password, route: route, endpoint: SSHEndpoint(host: "target", port: 22))
        let dec = await coord.resolve(request: SSHConnectionRequest(requirements: req))
        guard case .compatibility(let reason) = dec else { return XCTFail() }
        XCTAssertEqual(reason, .jumpHost)
    }

    func testCoordinatorForwardGoesCompatibility() async {
        let coord = SSHSessionCoordinator()
        let req = SSHConnectionRequirements(authentication: .password, route: .direct, service: .forward, endpoint: SSHEndpoint(host: "h", port: 22))
        let dec = await coord.resolve(request: SSHConnectionRequest(requirements: req))
        guard case .compatibility = dec else { return XCTFail("forward should be compatibility") }
    }

    func testCoordinatorSecureEnclaveGoesNative() async {
        let coord = SSHSessionCoordinator()
        let req = SSHConnectionRequirements(authentication: .secureEnclave, route: .direct, endpoint: SSHEndpoint(host: "h", port: 22))
        let dec = await coord.resolve(request: SSHConnectionRequest(requirements: req))
        guard case .native = dec else { return XCTFail("secureEnclave should be native") }
    }

    func testCoordinatorDirectPasswordGoesNativeWithFallback() async {
        let coord = SSHSessionCoordinator()
        let req = SSHConnectionRequirements(authentication: .password, route: .direct, endpoint: SSHEndpoint(host: "h", port: 22))
        let dec = await coord.resolve(request: SSHConnectionRequest(requirements: req))
        guard case .nativeWithCompatibilityFallback = dec else { return XCTFail("direct should be fallback") }
    }

    func testCoordinatorCachedProfileHitSkipsProbe() async {
        let coord = SSHSessionCoordinator()
        let req = SSHConnectionRequirements(authentication: .password, route: .direct, endpoint: SSHEndpoint(host: "h", port: 22))
        let cached = SSHSessionCoordinator.CachedProfile(backend: .compatibility, reason: .kexMismatch, isValid: true, algorithms: nil)
        let dec = await coord.resolve(request: SSHConnectionRequest(requirements: req), cachedProfile: cached)
        guard case .compatibility(let reason) = dec else { return XCTFail() }
        XCTAssertEqual(reason, .kexMismatch)
    }

    func testCoordinatorCachedNativeSkipsProbe() async {
        let coord = SSHSessionCoordinator()
        let req = SSHConnectionRequirements(authentication: .password, route: .direct, endpoint: SSHEndpoint(host: "h", port: 22))
        let cached = SSHSessionCoordinator.CachedProfile(backend: .native, reason: .modern, isValid: true, algorithms: nil)
        let dec = await coord.resolve(request: SSHConnectionRequest(requirements: req), cachedProfile: cached)
        guard case .native = dec else { return XCTFail() }
    }

    // MARK: - Profile policy TTL

    func testPolicyReasonIgnoresExpiry() {
        let past = Date().addingTimeInterval(-8*24*3600)
        let profile = SSHBackendProfile(
            host: "h", port: 22, authMethodRaw: SSHRoutingAuthMethod.password.rawValue,
            backendRaw: SSHBackendType.compatibility.rawValue, reasonRaw: SSHBackendReason.jumpHost.rawValue,
            detectedAt: past, expiresAt: past
        )
        XCTAssertTrue(profile.isPolicyReason)
        XCTAssertTrue(profile.isValid) // should be valid despite expired
    }

    func testCapabilityReasonRespectsExpiry() {
        let past = Date().addingTimeInterval(-8*24*3600)
        let profile = SSHBackendProfile(
            host: "h", port: 22, authMethodRaw: SSHRoutingAuthMethod.password.rawValue,
            backendRaw: SSHBackendType.compatibility.rawValue, reasonRaw: SSHBackendReason.kexMismatch.rawValue,
            detectedAt: past, expiresAt: past
        )
        XCTAssertFalse(profile.isPolicyReason)
        XCTAssertFalse(profile.isValid)
    }

    func testForcedCompatibilityIsPolicy() {
        let profile = SSHBackendProfile(
            host: "h", port: 22, authMethodRaw: SSHRoutingAuthMethod.password.rawValue,
            backendRaw: SSHBackendType.compatibility.rawValue, reasonRaw: SSHBackendReason.forcedCompatibility.rawValue
        )
        XCTAssertTrue(profile.isPolicyReason)
        XCTAssertTrue(profile.isValid)
    }
}
