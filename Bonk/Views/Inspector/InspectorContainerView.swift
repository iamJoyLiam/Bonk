//
//  InspectorContainerView.swift
//  Bonk
//
//  Right inspector panel — switches between AI and Snippets/History.
//

import SwiftData
import SwiftUI

struct InspectorContainerView: View {
    @Environment(I18n.self) var i18n
    @Environment(WorkspaceManager.self) private var workspace
    @Query(sort: \Snippet.sortOrder) private var snippets: [Snippet]
    @Bindable var sessionManager: SessionManager

    var body: some View {
        Group {
            switch workspace.activeRightPanel {
            case .none:
                EmptyView()
            case .ai:
                aiPanel
            case .snippetsHistory:
                snippetsHistoryPanel
            }
        }
    }

    // MARK: - AI Panel (pure AI chat, no tabs)

    private var aiPanel: some View {
        AIChatSidebarView(
            sshService: sessionManager.activeTab?.session?.sshService,
            onPaste: { text in
                sessionManager.sendTextToActiveTab(text)
            }
        )
    }

    // MARK: - Snippets/History Panel (with internal tab switch)

    private var snippetsHistoryPanel: some View {
        VStack(spacing: 0) {
            // Tab switcher
            Picker("", selection: Binding(
                get: { workspace.snippetsHistoryTab },
                set: { workspace.snippetsHistoryTab = $0 }
            )) {
                Text(i18n.t(.snippets)).tag(WorkspaceManager.SnippetsHistoryTab.snippets)
                Text(i18n.t(.commandHistory)).tag(WorkspaceManager.SnippetsHistoryTab.history)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Content
            switch workspace.snippetsHistoryTab {
            case .snippets:
                SnippetInspectorView(sessionManager: sessionManager)
            case .history:
                CommandHistoryInspectorView(
                    snippetCategories: Array(Set(snippets.map(\.category))).sorted(),
                    sessionManager: sessionManager
                )
            }
        }
    }
}
