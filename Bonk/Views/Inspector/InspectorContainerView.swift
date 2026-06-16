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

    // Placeholder: in production, this would be connected to a real CommandHistory model
    @State private var historyEntries: [HistoryEntry] = []

    struct HistoryEntry: Identifiable {
        let id = UUID()
        let command: String
        let timestamp: Date
        let exitCode: Int32?
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
                    historyEntries.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .help(i18n.t(.clearHistory))
                .disabled(historyEntries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // History list
            if historyEntries.isEmpty {
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
                        ForEach(historyEntries) { entry in
                            historyRow(entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(entry.exitCode == 0 ? .green : .red)

            Text(entry.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(entry.timestamp, style: .time)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                // Re-execute command
                if let activeTab = sessionManager.activeTab {
                    let bytes = Array(entry.command.utf8 + [13])
                    Task { try? await sessionManager.sendInput(bytes[...], to: activeTab.id) }
                }
            } label: {
                Label(i18n.t(.rerunCommand), systemImage: "arrow.clockwise")
            }

            Button {
                // Save to snippets
                let snippet = Snippet(
                    name: entry.command,
                    command: entry.command,
                    category: "History"
                )
                modelContext.insert(snippet)
            } label: {
                Label(i18n.t(.saveToSnippets), systemImage: "text.badge.plus")
            }

            Divider()

            Button {
                // Copy command
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.command, forType: .string)
            } label: {
                Label(i18n.t(.copy), systemImage: "doc.on.doc")
            }
        }
    }
}
