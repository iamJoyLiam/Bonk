//
//  SidebarView.swift
//  Bonk
//
//  Left sidebar: host list only. Serial port accessed via menu bar.
//

import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(I18n.self) var i18n
    @Environment(WorkspaceManager.self) private var workspace
    @Bindable var sessionManager: SessionManager
    @Query private var allPreferences: [UserPreferences]

    private var preferences: UserPreferences {
        allPreferences.first ?? UserPreferences()
    }

    var body: some View {
        HostListView(
            sessionManager: sessionManager,
            defaultPort: preferences.defaultPort
        )
    }
}
