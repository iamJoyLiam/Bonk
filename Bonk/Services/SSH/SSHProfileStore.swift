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
        return all.first { $0.routeData == routeData && $0.isValid }
    }

    func save(
        _ req: SSHConnectionRequirements,
        backend: SSHBackendType,
        reason: SSHBackendReason,
        classification: SSHFailureClassification? = nil,
        algorithms: SSHAlgorithmRequirements? = nil
    ) {
        // Upsert: remove existing for same key
        if let existing = profile(for: req) {
            context.delete(existing)
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
            macAlgorithms: algorithms?.mac ?? []
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
