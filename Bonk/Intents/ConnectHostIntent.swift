//
//  ConnectHostIntent.swift
//  Bonk
//
//  App Intent: connect to a saved host from Siri / Spotlight / Shortcuts.
//
//  Purely additive — the handoff goes through the bonk:// URL scheme and the
//  existing connection flow (SessionManager.openHost) is untouched.
//  AppIntents is available since macOS 13, so with the 15.0 deployment
//  target this file needs no @available guards and behaves identically
//  on macOS 15 / 26 / 27.
//

import AppIntents
import AppKit
import Foundation
import SwiftData

// MARK: - Entity

/// A saved host (SSH or serial), addressable by Siri and Shortcuts.
struct HostEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: LocalizedStringResource(
            "Host",
            table: "AppIntents"
        ))
    }

    /// Matches HostItem.id so the app can resolve it from the URL.
    let id: UUID
    let name: String
    /// "user@address" (SSH) or device path (serial), shown as subtitle.
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(detail)"
        )
    }

    static let defaultQuery = HostQuery()
}

extension HostEntity {
    init(_ item: HostItem) {
        id = item.id
        name = item.name
        if item.isSerial == true {
            detail = item.host
        } else {
            detail = "\(item.username)@\(item.host):\(item.port)"
        }
    }
}

// MARK: - Query

struct HostQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [HostEntity.ID]) async throws -> [HostEntity] {
        try await allHostItems()
            .filter { identifiers.contains($0.id) }
            .map(HostEntity.init)
    }

    /// Siri / Shortcuts suggestions: favorites first, then most recently used.
    func suggestedEntities() async throws -> [HostEntity] {
        try await allHostItems()
            .sorted {
                if $0.isFavorite != $1.isFavorite {
                    return $0.isFavorite
                }
                return ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast)
            }
            .prefix(12)
            .map(HostEntity.init)
    }

    /// Type-to-filter by host name or address.
    func entities(matching string: String) async throws -> [HostEntity] {
        let needle = string.lowercased()
        return try await allHostItems()
            .filter {
                $0.name.lowercased().contains(needle)
                    || $0.host.lowercased().contains(needle)
            }
            .map(HostEntity.init)
    }

    // MARK: Private

    /// Reads through a throwaway ModelContext (same-thread, synchronous),
    /// so this never touches whatever context the UI is using.
    private func allHostItems() throws -> [HostItem] {
        let context = ModelContext(BonkApp.sharedModelContainer)
        var descriptor = FetchDescriptor<HostItem>()
        descriptor.fetchLimit = 100
        return (try? context.fetch(descriptor)) ?? []
    }
}

// MARK: - Intent

/// "Connect to a saved host with Bonk" — Siri, Spotlight, and Shortcuts.
struct ConnectHostIntent: AppIntent {
    static var title: LocalizedStringResource {
        LocalizedStringResource("Connect to Host", table: "AppIntents")
    }

    static var description: IntentDescription? {
        IntentDescription(LocalizedStringResource(
            "Open a terminal tab and connect to one of your saved hosts.",
            table: "AppIntents"
        ))
    }

    @Parameter(title: LocalizedStringResource("Host", table: "AppIntents"))
    var host: HostEntity

    func perform() async throws -> some IntentResult {
        var components = URLComponents()
        components.scheme = "bonk"
        components.host = "connect"
        components.queryItems = [URLQueryItem(name: "host", value: host.id.uuidString)]
        guard let url = components.url else {
            throw ConnectHostError.badURL
        }
        // Works whether or not the app is running: the URL launch wakes it
        // and BonkAppDelegate routes to SessionManager.openHost.
        NSWorkspace.shared.open(url)
        let format = Bundle.main.localizedString(forKey: "Connected to %@.", value: nil, table: "AppIntents")
        return .result(dialog: IntentDialog(stringLiteral: String(format: format, host.name)))
    }
}

enum ConnectHostError: Error {
    case badURL
}

// MARK: - Shortcuts

struct BonkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectHostIntent(),
            phrases: [
                "Connect to \(\.$host) with \(.applicationName)",
                "用\(.applicationName)连接\(\.$host)",
            ],
            shortTitle: LocalizedStringResource("Connect Host", table: "AppIntents"),
            systemImageName: "terminal"
        )
    }
}
