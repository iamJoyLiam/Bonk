//
//  AppStore.swift
//  Bonk
//
//  Central state manager for the application.
//  Provides a single source of truth for application state.
//

import SwiftUI

/// Central state manager for the application.
@Observable @MainActor
final class AppStore {
    static let shared = AppStore()

    // MARK: - State

    var sessions: [UUID: SessionState] = [:]
    var searchState: SearchState = .init()
    var uiState: UIState = .init()

    // MARK: - Sub-state Types

    struct SessionState {
        var connectionState: SSHConnectionState = .disconnected
        var currentDirectory: String?
        var errorMessage: String?
    }

    struct SearchState {
        var searchText: String = ""
        var matchCount: Int = 0
        var currentMatch: Int = 0
        var isSearching: Bool = false
    }

    struct UIState {
        var activeTabID: UUID?
        var showSearch: Bool = false
        var showAI: Bool = false
        var showSFTP: Bool = false
        var showInspector: Bool = false
    }

    private init() {}

    // MARK: - Actions (Action/Reducer Pattern)

    /// Dispatch an action to update state.
    func dispatch(_ action: Action) {
        let newState = reduce(state: currentState, action: action)
        applyState(newState)
    }

    /// Get current state snapshot.
    private var currentState: AppState {
        AppState(sessions: sessions, searchState: searchState, uiState: uiState)
    }

    /// Apply new state.
    private func applyState(_ state: AppState) {
        sessions = state.sessions
        searchState = state.searchState
        uiState = state.uiState
    }

    /// Pure reducer function - takes current state and action, returns new state.
    private func reduce(state: AppState, action: Action) -> AppState {
        var newState = state

        switch action {
        case let .selectTab(id):
            newState.uiState.activeTabID = id

        case let .updateSearchText(text):
            newState.searchState.searchText = text

        case let .updateSearchResults(current, total):
            newState.searchState.currentMatch = current
            newState.searchState.matchCount = total

        case .clearSearch:
            newState.searchState = SearchState()

        case .toggleSearch:
            newState.uiState.showSearch.toggle()

        case .toggleAI:
            newState.uiState.showAI.toggle()

        case .toggleSFTP:
            newState.uiState.showSFTP.toggle()

        case .toggleInspector:
            newState.uiState.showInspector.toggle()

        case let .updateSessionState(id, state):
            newState.sessions[id] = state
        }

        return newState
    }

    /// State snapshot for reducer.
    private struct AppState {
        var sessions: [UUID: SessionState]
        var searchState: SearchState
        var uiState: UIState
    }

    // MARK: - Action Enum

    enum Action {
        case selectTab(UUID)
        case updateSearchText(String)
        case updateSearchResults(current: Int, total: Int)
        case clearSearch
        case toggleSearch
        case toggleAI
        case toggleSFTP
        case toggleInspector
        case updateSessionState(UUID, SessionState)
    }
}
