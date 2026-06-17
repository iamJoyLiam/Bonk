//
//  EventPublisher.swift
//  Bonk
//
//  Lightweight event bus for decoupled component communication.
//  Enables publish-subscribe pattern across the application.
//

import Foundation

/// Lightweight event bus for decoupled component communication.
@MainActor
final class EventPublisher {
    static let shared = EventPublisher()

    private var subscribers: [String: [(id: UUID, handler: (Any) -> Void)]] = [:]

    private init() {}

    // MARK: - Public API

    /// Subscribe to an event type.
    @discardableResult
    func subscribe<T>(_ type: T.Type, handler: @escaping (T) -> Void) -> UUID {
        let id = UUID()
        let key = String(describing: type)
        subscribers[key, default: []].append((id: id, handler: { event in
            if let typedEvent = event as? T {
                handler(typedEvent)
            }
        }))
        return id
    }

    /// Unsubscribe from an event.
    func unsubscribe(_ id: UUID) {
        for key in subscribers.keys {
            subscribers[key]?.removeAll { $0.id == id }
        }
    }

    /// Publish an event to all subscribers.
    func publish<T>(_ event: T) {
        let key = String(describing: T.self)
        let handlers = subscribers[key] ?? []

        for handler in handlers {
            handler.handler(event)
        }
    }
}

// MARK: - Event Types

/// Search-related events.
enum SearchEvent {
    case resultsUpdated(current: Int, total: Int)
    case cleared
    case textChanged(String)
}

/// Session-related events.
enum SessionEvent {
    case connected(tabID: UUID)
    case disconnected(tabID: UUID)
    case error(tabID: UUID, error: Error)
    case stateChanged(tabID: UUID, state: SSHConnectionState)
}

/// UI-related events.
enum UIEvent {
    case themeChanged
    case fontChanged
    case languageChanged
    case showSearch
    case hideSearch
    case showAI
    case hideAI
}

/// Connection-related events.
enum ConnectionEvent {
    case connecting(tabID: UUID)
    case reconnecting(tabID: UUID, attempt: Int, maxAttempts: Int)
    case failed(tabID: UUID, error: Error)
}
