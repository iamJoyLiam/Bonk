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
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .font(.system(size: AppStyle.fontBody))
                Text(i18n.t(.commandHistory))
                    .font(.system(size: AppStyle.fontRegular, weight: .medium))
                Spacer()
                Button { showClearConfirm = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: AppStyle.fontSmall))
                        .foregroundStyle(.secondary)
                }
                .help(i18n.t(.clearHistory))
                .disabled(GlobalCommandHistory.shared.commands.isEmpty)
            }
            .padding(.horizontal, AppStyle.spacingL)
            .padding(.vertical, AppStyle.spacingM)
            .alert(i18n.t(.clearHistoryConfirm), isPresented: $showClearConfirm) {
                Button(i18n.t(.delete), role: .destructive) {
                    GlobalCommandHistory.shared.clear()
                }
                Button(i18n.t(.cancel), role: .cancel) {}
            }

            Divider()

            // History list
            let commands = GlobalCommandHistory.shared.commands
            if commands.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: AppStyle.fontHero))
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
            statusIcon(for: entry)
            commandInfo(for: entry)
            Spacer()
            actionButtons(for: entry)
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingS)
        .contentShape(Rectangle())
        .contextMenu { historyContextMenu(for: entry) }
    }

    @ViewBuilder
    private func statusIcon(for entry: CommandRecord) -> some View {
        if entry.exitCode != nil {
            Image(systemName: entry.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: AppStyle.fontBody))
                .foregroundStyle(entry.isSuccess ? .green : .red)
        } else {
            Image(systemName: "circle")
                .font(.system(size: AppStyle.fontBody))
                .foregroundStyle(.tertiary)
        }
    }

    private func commandInfo(for entry: CommandRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.command)
                .font(.system(size: AppStyle.fontBody, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(entry.startTime, style: .time)
                    .font(.system(size: AppStyle.fontSmallest, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(entry.durationFormatted)
                    .font(.system(size: AppStyle.fontSmallest, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func actionButtons(for entry: CommandRecord) -> some View {
        Button {
            sessionManager.sendTextToActiveTab(entry.command)
        } label: {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: AppStyle.fontMedium))
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .help(i18n.t(.rerunCommand))

        Button {
            GlobalCommandHistory.shared.delete(entry)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: AppStyle.fontSmall))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(i18n.t(.delete))
    }

    @ViewBuilder
    private func historyContextMenu(for entry: CommandRecord) -> some View {
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
