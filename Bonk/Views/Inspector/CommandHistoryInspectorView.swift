//
//  CommandHistoryInspectorView.swift
//  Bonk
//
//  Command history panel in the inspector sidebar.
//

import SwiftData
import SwiftUI

struct CommandHistoryInspectorView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    var snippetCategories: [String] = []
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
                Button { history?.clear() } label: {
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
            SnippetEditSheet(
                snippet: nil,
                modelContext: modelContext,
                initialCommand: entry.command,
                existingCategories: snippetCategories
            )
            .environment(i18n)
        }
    }

    private func historyRow(_ entry: CommandRecord) -> some View {
        HStack(spacing: 10) {
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

            // Execute button
            Button {
                sessionManager.sendTextToActiveTab(entry.command)
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help(i18n.t(.rerunCommand))

            // Delete button
            Button {
                history?.commands.removeAll { $0.id == entry.id }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(i18n.t(.delete))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                sessionManager.sendTextToActiveTab(entry.command)
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
