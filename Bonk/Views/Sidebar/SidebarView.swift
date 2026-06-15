//
//  SidebarView.swift
//  Bonk
//
//  Left sidebar: host list only. Serial port accessed via menu bar.
//

import SwiftData
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var i18n: I18n
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
