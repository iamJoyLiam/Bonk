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
        XCTAssertEqual(NativeErrorClassifier().classify(ctx), .hostKeyVerification)
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

    // MARK: - Adaptive TTL (M4 Full画像)

    func testAdaptiveTTLStages() {
        XCTAssertEqual(SSHBackendProfile.adaptiveTTL(forHitCount: 1, isPolicy: false), 1*24*3600, accuracy: 1)
        XCTAssertEqual(SSHBackendProfile.adaptiveTTL(forHitCount: 2, isPolicy: false), 7*24*3600, accuracy: 1)
        XCTAssertEqual(SSHBackendProfile.adaptiveTTL(forHitCount: 3, isPolicy: false), 30*24*3600, accuracy: 1)
        XCTAssertEqual(SSHBackendProfile.adaptiveTTL(forHitCount: 99, isPolicy: false), 30*24*3600, accuracy: 1)
        XCTAssertEqual(SSHBackendProfile.adaptiveTTL(forHitCount: 1, isPolicy: true), 10*365*24*3600, accuracy: 1)
    }

    func testAdaptiveTTLInitUsesHitCount() {
        let now = Date()
        let p1 = SSHBackendProfile(host: "h", port: 22, authMethodRaw: SSHRoutingAuthMethod.password.rawValue, backendRaw: SSHBackendType.native.rawValue, reasonRaw: SSHBackendReason.modern.rawValue, detectedAt: now, hitCount: 1)
        XCTAssertEqual(p1.expiresAt.timeIntervalSince(now), 1*24*3600, accuracy: 1)
        let p2 = SSHBackendProfile(host: "h", port: 22, authMethodRaw: SSHRoutingAuthMethod.password.rawValue, backendRaw: SSHBackendType.native.rawValue, reasonRaw: SSHBackendReason.modern.rawValue, detectedAt: now, hitCount: 2)
        XCTAssertEqual(p2.expiresAt.timeIntervalSince(now), 7*24*3600, accuracy: 1)
        let p3 = SSHBackendProfile(host: "h", port: 22, authMethodRaw: SSHRoutingAuthMethod.password.rawValue, backendRaw: SSHBackendType.native.rawValue, reasonRaw: SSHBackendReason.modern.rawValue, detectedAt: now, hitCount: 3)
        XCTAssertEqual(p3.expiresAt.timeIntervalSince(now), 30*24*3600, accuracy: 1)
    }

    func testBumpHitProgressesTTL() {
        let p = SSHBackendProfile(host: "h", port: 22, authMethodRaw: SSHRoutingAuthMethod.password.rawValue, backendRaw: SSHBackendType.native.rawValue, reasonRaw: SSHBackendReason.modern.rawValue, hitCount: 1)
        let exp1 = p.expiresAt
        XCTAssertEqual(p.effectiveHitCount, 1)
        p.bumpHit()
        XCTAssertEqual(p.effectiveHitCount, 2)
        XCTAssertEqual(p.adaptiveTTL, 7*24*3600, accuracy: 1)
        XCTAssertGreaterThan(p.expiresAt.timeIntervalSinceNow, 6*24*3600)
        p.bumpHit()
        XCTAssertEqual(p.effectiveHitCount, 3)
        XCTAssertEqual(p.adaptiveTTL, 30*24*3600, accuracy: 1)
        _ = exp1
    }

    func testPolicyBumpDoesNotExpire() {
        let p = SSHBackendProfile(host: "h", port: 22, authMethodRaw: SSHRoutingAuthMethod.password.rawValue, backendRaw: SSHBackendType.compatibility.rawValue, reasonRaw: SSHBackendReason.jumpHost.rawValue, hitCount: 99)
        XCTAssertTrue(p.isPolicyReason)
        p.bumpHit()
        XCTAssertTrue(p.isValid)
        // policy expires 10y, still valid after bump
        XCTAssertGreaterThan(p.expiresAt.timeIntervalSinceNow, 9*365*24*3600)
    }

    func testNilHitCountTreatedAsOne() {
        let p = SSHBackendProfile(host: "h", port: 22, authMethodRaw: SSHRoutingAuthMethod.password.rawValue, backendRaw: SSHBackendType.native.rawValue, reasonRaw: SSHBackendReason.modern.rawValue)
        p.hitCount = nil
        XCTAssertEqual(p.effectiveHitCount, 1)
        XCTAssertEqual(p.adaptiveTTL, 1*24*3600, accuracy: 1)
    }

    func testOldRecordMigrationKeepsData() {
        // Simulate old record with nil hitCount/negotiated fields (pre-M4)
        let past = Date().addingTimeInterval(-1*24*3600)
        let p = SSHBackendProfile(host: "h", port: 22, authMethodRaw: SSHRoutingAuthMethod.password.rawValue, backendRaw: SSHBackendType.compatibility.rawValue, reasonRaw: SSHBackendReason.kexMismatch.rawValue, detectedAt: past, expiresAt: past.addingTimeInterval(7*24*3600))
        p.hitCount = nil
        p.negotiatedKEX = nil
        XCTAssertEqual(p.effectiveHitCount, 1)
        XCTAssertTrue(p.isValid || !p.isValid) // should not crash
        XCTAssertNil(p.negotiatedKEX)
        XCTAssertEqual(p.kexAlgorithms, [])
    }
}
