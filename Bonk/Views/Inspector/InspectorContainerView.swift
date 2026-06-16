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
            sshService: sessionManager.activeTab?.session?.sshService,
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
                CommandHistoryInspectorView(sessionManager: sessionManager)
            }
        }
    }
}

// MARK: - Command History Inspector View

struct CommandHistoryInspectorView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Bindable var sessionManager: SessionManager
    @State private var snippetSource: CommandRecord?

    private var history: CommandHistory? {
        sessionManager.activeTab?.session?.commandHistory
    }

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
                Button {
                    history?.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .help(i18n.t(.clearHistory))
                .disabled(history?.commands.isEmpty != false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // History list
            let commands = history?.commands ?? []
            if commands.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.noCommands))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(commands) { entry in
                            historyRow(entry)
                        }
                    }
                }
            }
        }
        .sheet(item: $snippetSource) { entry in
            SnippetEditSheet(snippet: nil, modelContext: modelContext, initialCommand: entry.command)
                .environment(i18n)
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: CommandRecord) -> some View {
        HStack(spacing: 10) {
            // Status icon
            if entry.exitCode != nil {
                Image(systemName: entry.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(entry.isSuccess ? .green : .red)
            } else {
                Image(systemName: "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.startTime, style: .time)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(entry.durationFormatted)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                if let activeTab = sessionManager.activeTab {
                    let bytes = Array(entry.command.utf8 + [13])
                    Task { try? await sessionManager.sendInput(bytes[...], to: activeTab.id) }
                }
            } label: {
                Label(i18n.t(.rerunCommand), systemImage: "arrow.clockwise")
            }

            Button {
                snippetSource = entry
            } label: {
                Label(i18n.t(.saveToSnippets), systemImage: "text.badge.plus")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.command, forType: .string)
            } label: {
                Label(i18n.t(.copy), systemImage: "doc.on.doc")
            }
        }
    }
}
