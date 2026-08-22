import Foundation
import SwiftData

/// VNext — Profile cache access (T4.1).
/// Thin wrapper over SwiftData; SessionManager owns the ModelContext.
@MainActor
final class SSHProfileStore {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func profile(for req: SSHConnectionRequirements) -> SSHBackendProfile? {
        let routeData = try? JSONEncoder().encode(req.route)
        let host = req.endpoint.host
        let port = Int(req.endpoint.port)
        let authRaw = req.authentication.rawValue
        let predicate = #Predicate<SSHBackendProfile> { p in
            p.host == host && p.port == port && p.authMethodRaw == authRaw
        }
        let desc = FetchDescriptor<SSHBackendProfile>(predicate: predicate)
        guard let all = try? context.fetch(desc) else { return nil }
        // Route is not predicate-friendly (Data); filter in memory
        // Prefer valid entries; policy entries stay valid past TTL (§6.3)
        return all.first { $0.routeData == routeData && $0.isValid }
    }

    /// Raw fetch ignoring TTL/fingerprint — for save upsert decision.
    private func rawProfile(for req: SSHConnectionRequirements) -> SSHBackendProfile? {
        let routeData = try? JSONEncoder().encode(req.route)
        let host = req.endpoint.host
        let port = Int(req.endpoint.port)
        let authRaw = req.authentication.rawValue
        let predicate = #Predicate<SSHBackendProfile> { p in
            p.host == host && p.port == port && p.authMethodRaw == authRaw
        }
        let desc = FetchDescriptor<SSHBackendProfile>(predicate: predicate)
        guard let all = try? context.fetch(desc) else { return nil }
        return all.first { $0.routeData == routeData }
    }

    /// Hit without side effect — bump is done in save() after successful connection.
    func validatedProfile(for req: SSHConnectionRequirements) -> SSHBackendProfile? {
        profile(for: req)
    }

    /// Return all profiles for a host (any auth/route) — for Host Inspector list.
    func profiles(forHost host: String, port: Int) -> [SSHBackendProfile] {
        let predicate = #Predicate<SSHBackendProfile> { p in
            p.host == host && p.port == port
        }
        let desc = FetchDescriptor<SSHBackendProfile>(predicate: predicate)
        guard let all = try? context.fetch(desc) else { return [] }
        return all.sorted { $0.detectedAt > $1.detectedAt }
    }

    /// Remove all profiles for a host — for Host Inspector "Re-detect" bulk clear.
    func removeAll(forHost host: String, port: Int) {
        let predicate = #Predicate<SSHBackendProfile> { p in
            p.host == host && p.port == port
        }
        let desc = FetchDescriptor<SSHBackendProfile>(predicate: predicate)
        guard let all = try? context.fetch(desc) else { return }
        for p in all { context.delete(p) }
        try? context.save()
    }

    func save(
        _ req: SSHConnectionRequirements,
        backend: SSHBackendType,
        reason: SSHBackendReason,
        classification: SSHFailureClassification? = nil,
        algorithms: SSHAlgorithmRequirements? = nil,
        negotiatedKEX: String? = nil,
        negotiatedHostKey: String? = nil,
        negotiatedCipher: String? = nil,
        negotiatedMAC: String? = nil
    ) {
        // Upsert with Adaptive TTL progression:
        // - same backend/reason/algorithms → bump hit (1d→7d→30d)
        // - expired or different decision → reset to 1d
        // - policy (jumpHost/forcedCompatibility) never expires but still tracks hitCount/lastHitAt
        if let existing = rawProfile(for: req) {
            let sameDecision = existing.backendRaw == backend.rawValue
                && existing.reasonRaw == reason.rawValue
                && existing.kexAlgorithms == (algorithms?.kex ?? [])
                && existing.hostKeyAlgorithms == (algorithms?.hostKey ?? [])
                && existing.cipherAlgorithms == (algorithms?.cipher ?? [])
                && existing.macAlgorithms == (algorithms?.mac ?? [])
            if sameDecision, existing.isValid {
                existing.bumpHit()
                if let v = negotiatedKEX { existing.negotiatedKEX = v }
                if let v = negotiatedHostKey { existing.negotiatedHostKey = v }
                if let v = negotiatedCipher { existing.negotiatedCipher = v }
                if let v = negotiatedMAC { existing.negotiatedMAC = v }
                if let c = classification?.rawValue { existing.classificationRaw = c }
                try? context.save()
                return
            } else {
                context.delete(existing)
            }
        }
        let routeData = try? JSONEncoder().encode(req.route)
        let p = SSHBackendProfile(
            host: req.endpoint.host,
            port: Int(req.endpoint.port),
            authMethodRaw: req.authentication.rawValue,
            routeData: routeData,
            backendRaw: backend.rawValue,
            reasonRaw: reason.rawValue,
            classificationRaw: classification?.rawValue,
            kexAlgorithms: algorithms?.kex ?? [],
            hostKeyAlgorithms: algorithms?.hostKey ?? [],
            cipherAlgorithms: algorithms?.cipher ?? [],
            macAlgorithms: algorithms?.mac ?? [],
            hitCount: 1,
            lastHitAt: Date(),
            negotiatedKEX: negotiatedKEX,
            negotiatedHostKey: negotiatedHostKey,
            negotiatedCipher: negotiatedCipher,
            negotiatedMAC: negotiatedMAC
        )
        context.insert(p)
        try? context.save()
    }

    /// For Host Inspector Re-detect: remove cached profile
    func remove(for req: SSHConnectionRequirements) {
        if let existing = profile(for: req) {
            context.delete(existing)
            try? context.save()
        }
    }
}
