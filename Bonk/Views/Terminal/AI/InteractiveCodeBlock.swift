import SwiftUI

/// Parsed command block item that separates preceding comments from executable commands.
struct ParsedShellItem: Identifiable {
    let id = UUID()
    var commentLines: [String] = []
    var commandLines: [String] = []
    var commandText: String = ""
    var isCommand: Bool {
        !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ShellCommandParser {
    static func parse(code: String) -> [ParsedShellItem] {
        let lines = code.components(separatedBy: "\n")
        var items: [ParsedShellItem] = []
        var currentComments: [String] = []
        var currentCommandLines: [String] = []
        var inContinuation = false

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if inContinuation {
                currentCommandLines.append(rawLine)
                if !trimmed.hasSuffix("\\") {
                    inContinuation = false
                    let fullCmd = currentCommandLines.joined(separator: "\n")
                    items.append(ParsedShellItem(commentLines: currentComments, commandLines: currentCommandLines, commandText: fullCmd))
                    currentComments = []
                    currentCommandLines = []
                }
                continue
            }

            if trimmed.isEmpty {
                if !currentCommandLines.isEmpty {
                    let fullCmd = currentCommandLines.joined(separator: "\n")
                    items.append(ParsedShellItem(commentLines: currentComments, commandLines: currentCommandLines, commandText: fullCmd))
                    currentComments = []
                    currentCommandLines = []
                }
                continue
            }

            if trimmed.hasPrefix("#") {
                if !currentCommandLines.isEmpty {
                    let fullCmd = currentCommandLines.joined(separator: "\n")
                    items.append(ParsedShellItem(commentLines: currentComments, commandLines: currentCommandLines, commandText: fullCmd))
                    currentComments = []
                    currentCommandLines = []
                }
                currentComments.append(rawLine)
                continue
            }

            // Command line
            currentCommandLines.append(rawLine)
            if trimmed.hasSuffix("\\") {
                inContinuation = true
            } else {
                let fullCmd = currentCommandLines.joined(separator: "\n")
                items.append(ParsedShellItem(commentLines: currentComments, commandLines: currentCommandLines, commandText: fullCmd))
                currentComments = []
                currentCommandLines = []
            }
        }

        if !currentCommandLines.isEmpty {
            let fullCmd = currentCommandLines.joined(separator: "\n")
            items.append(ParsedShellItem(commentLines: currentComments, commandLines: currentCommandLines, commandText: fullCmd))
        } else if !currentComments.isEmpty {
            items.append(ParsedShellItem(commentLines: currentComments, commandLines: [], commandText: ""))
        }

        return items
    }
}

/// Interactive code block supporting single-line and individual multi-command execution.
struct InteractiveCodeBlock: View {
    @Environment(I18n.self) var i18n
    let code: String
    let language: String?
    var onRun: (@MainActor (String) -> Void)?
    @State private var copied = false
    @State private var justExecutedAll = false
    @State private var executedItemIds: Set<UUID> = []

    private var isShellLanguage: Bool {
        guard let lang = language?.lowercased() else { return true }
        return ["bash", "sh", "zsh", "shell"].contains(lang)
    }

    private var parsedItems: [ParsedShellItem] {
        if isShellLanguage {
            return ShellCommandParser.parse(code: code)
        }
        return []
    }

    private var commandItems: [ParsedShellItem] {
        parsedItems.filter(\.isCommand)
    }

    private var isMultiCommand: Bool {
        isShellLanguage && commandItems.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text((language ?? "sh").uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if isMultiCommand {
                        Text("• \(commandItems.count) \(i18n.lang.hasPrefix("zh") ? "个命令" : "commands")")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if isShellLanguage, let onRun {
                    if isMultiCommand {
                        Button {
                            justExecutedAll = true
                            onRun(code)
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                justExecutedAll = false
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: justExecutedAll ? "checkmark" : "play.fill")
                                    .font(.system(size: 9))
                                Text(justExecutedAll ? i18n.t(.aiSent) : (i18n.lang.hasPrefix("zh") ? "全部运行" : "Run All"))
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(justExecutedAll ? Color.green : Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Color.accentColor.opacity(justExecutedAll ? 0.2 : 0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            justExecutedAll = true
                            onRun(code)
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                justExecutedAll = false
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: justExecutedAll ? "checkmark" : "play.fill")
                                    .font(.system(size: 9))
                                Text(justExecutedAll ? i18n.t(.aiSent) : i18n.t(.aiRun))
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(justExecutedAll ? Color.green : Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Color.accentColor.opacity(justExecutedAll ? 0.2 : 0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9.5))
                        if copied {
                            Text(i18n.t(.copied))
                                .font(.system(size: 9.5, weight: .medium))
                        }
                    }
                    .foregroundStyle(copied ? Color.green : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(copied ? 0.2 : 0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))

            Divider().opacity(0.2)

            // Code content
            if isMultiCommand {
                multiCommandBody
            } else {
                HighlightedCodeLines(code: code)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }

    private var multiCommandBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parsedItems) { item in
                VStack(alignment: .leading, spacing: 2) {
                    // Preceding comments
                    if !item.commentLines.isEmpty {
                        ForEach(item.commentLines, id: \.self) { comment in
                            Text(comment)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }

                    // Command row with individual Run button
                    if item.isCommand {
                        let isRan = executedItemIds.contains(item.id)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("$")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .selectionDisabled(true)

                            Text(ShellSyntaxHighlighter.highlight(item.commandLines.joined(separator: "\n"), fontSize: 12))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if let onRun {
                                Button {
                                    executedItemIds.insert(item.id)
                                    onRun(item.commandText)
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .seconds(2))
                                        executedItemIds.remove(item.id)
                                    }
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: isRan ? "checkmark" : "play.fill")
                                            .font(.system(size: 8, weight: .bold))
                                        Text(isRan ? (i18n.lang.hasPrefix("zh") ? "已发送" : "Sent") : (i18n.lang.hasPrefix("zh") ? "运行" : "Run"))
                                            .font(.system(size: 9.5, weight: .medium))
                                    }
                                    .foregroundStyle(isRan ? Color.green : Color.accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(isRan ? 0.2 : 0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .padding(AppStyle.spacingML)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
