import Foundation
import SwiftData

/// VNext — Endpoint backend preference cache (T4.1).
/// One record per (host, port, authMethod, route). Stores the last successful
/// backend and the reason, with TTL + capability fingerprint for invalidation.
@Model
final class SSHBackendProfile {
    var id: UUID
    var host: String
    var port: Int
    var authMethodRaw: String        // SSHRoutingAuthMethod.rawValue
    var routeData: Data?             // JSON of SSHRoute.hops
    var backendRaw: String           // SSHBackendType.rawValue
    var reasonRaw: String            // SSHBackendReason.rawValue
    var classificationRaw: String?   // SSHFailureClassification.rawValue
    var kexAlgorithms: [String]
    var hostKeyAlgorithms: [String]
    var cipherAlgorithms: [String]
    var macAlgorithms: [String]
    var detectedAt: Date
    var expiresAt: Date
    var citadelVersion: String?
    var niosshVersion: String?

    init(
        id: UUID = UUID(),
        host: String,
        port: Int,
        authMethodRaw: String,
        routeData: Data? = nil,
        backendRaw: String,
        reasonRaw: String,
        classificationRaw: String? = nil,
        kexAlgorithms: [String] = [],
        hostKeyAlgorithms: [String] = [],
        cipherAlgorithms: [String] = [],
        macAlgorithms: [String] = [],
        detectedAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(7 * 24 * 3600),
        citadelVersion: String? = SSHCapabilityFingerprint.current.citadelVersion,
        niosshVersion: String? = SSHCapabilityFingerprint.current.niosshVersion
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.authMethodRaw = authMethodRaw
        self.routeData = routeData
        self.backendRaw = backendRaw
        self.reasonRaw = reasonRaw
        self.classificationRaw = classificationRaw
        self.kexAlgorithms = kexAlgorithms
        self.hostKeyAlgorithms = hostKeyAlgorithms
        self.cipherAlgorithms = cipherAlgorithms
        self.macAlgorithms = macAlgorithms
        self.detectedAt = detectedAt
        self.expiresAt = expiresAt
        self.citadelVersion = citadelVersion
        self.niosshVersion = niosshVersion
    }

    var isExpired: Bool { Date() > expiresAt }

    var isValid: Bool {
        guard !isExpired else { return false }
        // Fingerprint check — dependency upgrade invalidates
        let current = SSHCapabilityFingerprint.current
        if let cv = citadelVersion, cv != current.citadelVersion { return false }
        if let nv = niosshVersion, nv != current.niosshVersion { return false }
        return true
    }

    // Helpers for route
    var route: SSHRoute? {
        get {
            guard let data = routeData else { return nil }
            return try? JSONDecoder().decode(SSHRoute.self, from: data)
        }
        set {
            routeData = try? JSONEncoder().encode(newValue)
        }
    }

    var backendType: SSHBackendType? { SSHBackendType(rawValue: backendRaw) }
    var reason: SSHBackendReason? { SSHBackendReason(rawValue: reasonRaw) }
    var authMethod: SSHRoutingAuthMethod? { SSHRoutingAuthMethod(rawValue: authMethodRaw) }

    var algorithmRequirements: SSHAlgorithmRequirements? {
        guard !kexAlgorithms.isEmpty || !hostKeyAlgorithms.isEmpty || !cipherAlgorithms.isEmpty || !macAlgorithms.isEmpty else {
            return nil
        }
        return SSHAlgorithmRequirements(
            kex: kexAlgorithms,
            hostKey: hostKeyAlgorithms,
            cipher: cipherAlgorithms,
            mac: macAlgorithms
        )
    }
}
