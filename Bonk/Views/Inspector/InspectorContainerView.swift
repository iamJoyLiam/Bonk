//
//  InspectorContainerView.swift
//  Bonk
//
//  Right inspector panel — switches between AI and Snippets/History.
//

import SwiftUI

struct InspectorContainerView: View {
    @EnvironmentObject var i18n: I18n
    @Environment(WorkspaceManager.self) private var workspace
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

    @ViewBuilder
    private var aiPanel: some View {
        AIChatSidebarView(
            sshService: sessionManager.activeTab?.sshService,
            onPaste: { text in
                guard let activeTab = sessionManager.activeTab else { return }
                let bytes = Array(text.utf8 + [13])
                Task { try? await sessionManager.sendInput(bytes[...], to: activeTab.id) }
            }
        )
    }

    // MARK: - Snippets/History Panel (with internal tab switch)

    @ViewBuilder
    private var snippetsHistoryPanel: some View {
        VStack(spacing: 0) {
            // Tab switcher
            Picker("", selection: Binding(
                get: { workspace.snippetsHistoryTab },
                set: { workspace.snippetsHistoryTab = $0 }
            )) {
                ForEach(WorkspaceManager.SnippetsHistoryTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
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
                CommandHistoryInspectorView(sessionManager: sessionManager)
            }
        }
    }
}

// MARK: - Command History Inspector View

struct CommandHistoryInspectorView: View {
    @EnvironmentObject var i18n: I18n
    @Bindable var sessionManager: SessionManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Text(i18n.t(.commandHistory))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // History list (placeholder - will be connected to CommandHistory model)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<20, id: \.self) { index in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)

                            Text("command_\(index)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text("0.\(index)s")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }
}
