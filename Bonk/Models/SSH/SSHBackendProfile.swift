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
    // Stored as Data (JSON) — SwiftData cannot store [String] directly
    var kexData: Data?
    var hostKeyData: Data?
    var cipherData: Data?
    var macData: Data?
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
        self.kexData = kexAlgorithms.isEmpty ? nil : try? JSONEncoder().encode(kexAlgorithms)
        self.hostKeyData = hostKeyAlgorithms.isEmpty ? nil : try? JSONEncoder().encode(hostKeyAlgorithms)
        self.cipherData = cipherAlgorithms.isEmpty ? nil : try? JSONEncoder().encode(cipherAlgorithms)
        self.macData = macAlgorithms.isEmpty ? nil : try? JSONEncoder().encode(macAlgorithms)
        self.detectedAt = detectedAt
        self.expiresAt = expiresAt
        self.citadelVersion = citadelVersion
        self.niosshVersion = niosshVersion
    }

    // Transient decoded arrays
    var kexAlgorithms: [String] {
        get { kexData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { kexData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
    var hostKeyAlgorithms: [String] {
        get { hostKeyData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { hostKeyData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
    var cipherAlgorithms: [String] {
        get { cipherData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { cipherData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
    var macAlgorithms: [String] {
        get { macData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { macData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
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
