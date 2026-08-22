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
    // MARK: - M4 Full画像增量（全可选，旧库兼容，轻量迁移）
    var hitCount: Int? // nil→1，Adaptive TTL 1d→7d→30d 累进
    var lastHitAt: Date?
    var negotiatedKEX: String?
    var negotiatedHostKey: String?
    var negotiatedCipher: String?
    var negotiatedMAC: String?

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
        expiresAt: Date? = nil,
        citadelVersion: String? = SSHCapabilityFingerprint.current.citadelVersion,
        niosshVersion: String? = SSHCapabilityFingerprint.current.niosshVersion,
        hitCount: Int? = 1,
        lastHitAt: Date? = nil,
        negotiatedKEX: String? = nil,
        negotiatedHostKey: String? = nil,
        negotiatedCipher: String? = nil,
        negotiatedMAC: String? = nil
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
        self.hitCount = hitCount
        self.lastHitAt = lastHitAt
        self.negotiatedKEX = negotiatedKEX
        self.negotiatedHostKey = negotiatedHostKey
        self.negotiatedCipher = negotiatedCipher
        self.negotiatedMAC = negotiatedMAC
        // Adaptive TTL：1d→7d→30d，policy 永不过期（由 isValid 忽略 TTL），指纹另行失效
        if let exp = expiresAt {
            self.expiresAt = exp
        } else {
            let ttl = Self.adaptiveTTL(forHitCount: hitCount ?? 1, isPolicy: reasonRaw == SSHBackendReason.jumpHost.rawValue || reasonRaw == SSHBackendReason.forcedCompatibility.rawValue)
            self.expiresAt = detectedAt.addingTimeInterval(ttl)
        }
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

    /// Policy reasons (jumpHost / forcedCompatibility) never expire by TTL (§6.3)
    var isPolicyReason: Bool {
        reasonRaw == SSHBackendReason.jumpHost.rawValue
            || reasonRaw == SSHBackendReason.forcedCompatibility.rawValue
    }

    var isValid: Bool {
        // Policy entries ignore TTL — only fingerprint invalidates them
        if !isPolicyReason, isExpired { return false }
        // Fingerprint check — dependency upgrade invalidates even policy entries
        let current = SSHCapabilityFingerprint.current
        if let cv = citadelVersion, cv != current.citadelVersion { return false }
        if let nv = niosshVersion, nv != current.niosshVersion { return false }
        return true
    }

    // MARK: - Adaptive TTL (M4 Full画像)

    var effectiveHitCount: Int { hitCount ?? 1 }

    static func adaptiveTTL(forHitCount hit: Int, isPolicy: Bool) -> TimeInterval {
        if isPolicy { return 60 * 60 * 24 * 365 * 10 } // 10y effectively never
        switch hit {
        case 1: return 1 * 24 * 3600
        case 2: return 7 * 24 * 3600
        default: return 30 * 24 * 3600
        }
    }

    var adaptiveTTL: TimeInterval { Self.adaptiveTTL(forHitCount: effectiveHitCount, isPolicy: isPolicyReason) }

    /// 命中时累进：hitCount+1 并重算 expiresAt=now+adaptiveTTL，指纹保持当前
    func bumpHit() {
        let nextHit = effectiveHitCount + 1
        hitCount = min(nextHit, 100) // cap
        lastHitAt = Date()
        if !isPolicyReason {
            expiresAt = Date().addingTimeInterval(adaptiveTTL)
        }
        // 刷新指纹到当前版本，避免旧版本残留误判失效
        let cur = SSHCapabilityFingerprint.current
        citadelVersion = cur.citadelVersion
        niosshVersion = cur.niosshVersion
    }

    /// 重探测后重置为 1d 起步
    func resetToFirstHit() {
        hitCount = 1
        lastHitAt = nil
        detectedAt = Date()
        if !isPolicyReason {
            expiresAt = Date().addingTimeInterval(Self.adaptiveTTL(forHitCount: 1, isPolicy: false))
        }
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
