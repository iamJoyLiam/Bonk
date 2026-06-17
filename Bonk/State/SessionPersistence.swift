//
//  SessionPersistence.swift
//  Bonk
//
//  Manages session save/restore using SwiftData.
//

import Foundation
import SwiftData

/// Handles session persistence operations (save, restore, lookup).
@Observable @MainActor
final class SessionPersistence {
    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        modelContext = context
    }

    /// Save or update a session record for the given host.
    func saveSession(for hostItem: HostItem) {
        guard let modelContext else { return }
        let host = hostItem.host
        let port = hostItem.port
        let user = hostItem.username
        let all = (try? modelContext.fetch(FetchDescriptor<SavedSession>())) ?? []
        if let existing = all.first(where: { $0.host == host && $0.port == port && $0.username == user }) {
            existing.recordConnection()
        } else {
            let session = SavedSession(from: hostItem)
            modelContext.insert(session)
        }
    }

    /// Restore recently connected hosts (up to maxCount).
    func restoreHosts(maxCount: Int = 10) -> [HostItem] {
        guard let modelContext else { return [] }
        let desc = FetchDescriptor<SavedSession>(
            sortBy: [SortDescriptor(\.lastConnectedAt, order: .reverse)]
        )
        guard let saved = try? modelContext.fetch(desc) else { return [] }
        let allHosts = (try? modelContext.fetch(FetchDescriptor<HostItem>())) ?? []
        return saved.prefix(maxCount).compactMap { entry in
            allHosts.first(where: {
                $0.host == entry.host && $0.port == entry.port && $0.username == entry.username
            })
        }
    }

    /// Find a HostItem matching a saved session record.
    func findHost(for saved: SavedSession) -> HostItem? {
        guard let modelContext else { return nil }
        let allHosts = (try? modelContext.fetch(FetchDescriptor<HostItem>())) ?? []
        return allHosts.first(where: {
            $0.host == saved.host && $0.port == saved.port && $0.username == saved.username
        })
    }
}
