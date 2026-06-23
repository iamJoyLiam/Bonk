//
//  CommandHistoryView.swift
//  Bonk
//

import SwiftUI

/// Displays command execution history with duration and exit codes.
struct CommandHistoryView: View {
    @Environment(I18n.self) var i18n
    @Bindable var history: CommandHistory
    @Binding var isPresented: Bool
    let onRerun: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.blue)
                Text(i18n.t(.commandHistory))
                    .font(.headline)
                Spacer()
                Button {
                    history.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .help(i18n.t(.clearHistory))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Command list
            if history.commands.isEmpty, history.currentCommand == nil {
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
                        // Current running command
                        if let current = history.currentCommand {
                            commandRow(current, isRunning: true)
                        }

                        // History (newest first)
                        ForEach(history.commands.reversed()) { cmd in
                            commandRow(cmd, isRunning: false)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private func commandRow(_ cmd: CommandRecord, isRunning: Bool) -> some View {
        HStack(spacing: 10) {
            // Status icon
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: cmd.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(cmd.isSuccess ? .green : .red)
            }

            // Command text
            Text(cmd.command)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2)
                .foregroundStyle(isRunning ? .primary : .secondary)

            Spacer()

            // Duration
            Text(cmd.durationFormatted)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            // Rerun button
            if !isRunning {
                Button {
                    onRerun(cmd.command)
                    isPresented = false
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help(i18n.t(.rerunCommand))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            if !isRunning {
                Button {
                    onRerun(cmd.command)
                    isPresented = false
                } label: {
                    Label("Rerun", systemImage: "arrow.clockwise")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd.command, forType: .string)
                } label: {
                    Label("Copy Command", systemImage: "doc.on.doc")
                }
            }
        }
    }
}
