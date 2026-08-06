//
//  AppStore.swift
//  Bonk
//

import SwiftUI

/// Minimal app-wide UI state holder.
@Observable @MainActor
final class AppStore {
    static let shared = AppStore()

    var showSearch = false

    func toggleSearch() {
        showSearch.toggle()
    }

    private init() {}
}
