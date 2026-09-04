import SwiftUI

// MARK: - Slash Commands

enum AISlashCommand: String, CaseIterable, Identifiable {
    case clear = "/clear"
    case fix = "/fix"
    case explain = "/explain"
    case compact = "/compact"
    case help = "/help"

    var id: String { rawValue }

    var title: String { rawValue }

    var description: String {
        switch self {
        case .clear: "清空当前会话记录"
        case .fix: "诊断并修复上一个失败的终端命令"
        case .explain: "解释终端最新输出或错误信息"
        case .compact: "总结并压缩对话上下文"
        case .help: "查看可用指令与使用技巧"
        }
    }

    var icon: String {
        switch self {
        case .clear: "trash"
        case .fix: "wrench.and.screwdriver"
        case .explain: "questionmark.circle"
        case .compact: "arrow.down.right.and.arrow.up.left"
        case .help: "info.circle"
        }
    }
}

// MARK: - Context Mentions

enum AIContextMention: String, CaseIterable, Identifiable {
    case terminal = "@terminal"
    case history = "@history"
    case host = "@host"
    case selection = "@selection"

    var id: String { rawValue }

    var token: String { rawValue }

    var title: String { rawValue }

    var description: String {
        switch self {
        case .terminal: "当前终端屏幕输出（最近输出）"
        case .history: "最近执行的终端命令历史"
        case .host: "当前连接的主机信息与状态"
        case .selection: "终端当前选中的文本"
        }
    }

    var icon: String {
        switch self {
        case .terminal: "terminal"
        case .history: "clock.arrow.circlepath"
        case .host: "server.rack"
        case .selection: "selection.pin.in.out"
        }
    }
}

// MARK: - Autocomplete Popup View

struct SlashAndMentionPopup: View {
    let slashMatches: [AISlashCommand]
    let mentionMatches: [AIContextMention]
    var selectedIndex: Int = 0
    let onSelectSlash: (AISlashCommand) -> Void
    let onSelectMention: (AIContextMention) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !slashMatches.isEmpty {
                Text("快捷指令 (Slash Commands)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                ForEach(Array(slashMatches.enumerated()), id: \.offset) { index, cmd in
                    let isSelected = selectedIndex == index
                    Button {
                        onSelectSlash(cmd)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: cmd.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: .controlAccentColor))
                                .frame(width: 16)

                            Text(cmd.title)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)

                            Text(cmd.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !mentionMatches.isEmpty {
                if !slashMatches.isEmpty {
                    Divider().padding(.vertical, 2)
                }

                Text("上下文引用 (Context Mentions)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                ForEach(Array(mentionMatches.enumerated()), id: \.offset) { index, mention in
                    let isSelected = selectedIndex == (slashMatches.count + index)
                    Button {
                        onSelectMention(mention)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: mention.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(.blue)
                                .frame(width: 16)

                            Text(mention.title)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(nsColor: .controlAccentColor))

                            Text(mention.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().opacity(0.4)
            HStack(spacing: 8) {
                Text("⇥ / ↵ 选定   ↑↓ 选择   Esc 关闭")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
    }
}

// MARK: - Context Expansion Helper

enum ContextMentionResolver {
    /// Expand any @terminal, @history, @host, @selection tags in user text into detailed prompts.
    @MainActor
    static func expandMentions(
        in text: String,
        terminalContext: TerminalContext?,
        tab: TerminalTab?
    ) -> String {
        var result = text
        var attachments: [String] = []

        if result.contains("@terminal") {
            result = result.replacingOccurrences(of: "@terminal", with: "`@terminal`")
            let output = terminalContext?.terminalOutput
                ?? tab?.session?.ptySession?.recentOutput(maxLines: 50)
                ?? ""
            if !output.isEmpty {
                attachments.append("## Terminal Screen Output (@terminal):\n```\n\(output)\n```")
            }
        }

        if result.contains("@history") {
            result = result.replacingOccurrences(of: "@history", with: "`@history`")
            let history = terminalContext?.recentCommands
                ?? GlobalCommandHistory.shared.commands.suffix(15).map(\.command)
            if !history.isEmpty {
                attachments.append("## Recent Command History (@history):\n```\n" + history.joined(separator: "\n") + "\n```")
            }
        }

        if result.contains("@host") {
            result = result.replacingOccurrences(of: "@host", with: "`@host`")
            var hostInfo: [String] = []
            if let host = tab?.hostItem.host { hostInfo.append("Host: \(host)") }
            if let user = tab?.hostItem.username { hostInfo.append("User: \(user)") }
            if let os = tab?.session?.serverInfo?.os { hostInfo.append("OS: \(os)") }
            if let shell = tab?.session?.serverInfo?.shell { hostInfo.append("Shell: \(shell)") }
            if let cwd = tab?.currentDirectory { hostInfo.append("CWD: \(cwd)") }
            if !hostInfo.isEmpty {
                attachments.append("## Host Information (@host):\n" + hostInfo.joined(separator: "\n"))
            }
        }

        if result.contains("@selection") {
            result = result.replacingOccurrences(of: "@selection", with: "`@selection`")
            let sel = terminalContext?.selection ?? ""
            if !sel.isEmpty {
                attachments.append("## Terminal Selected Text (@selection):\n```\n\(sel)\n```")
            }
        }

        if attachments.isEmpty {
            return text
        }
        let intent = UserIntent.parse(rawInput: text, defaultExecutionRequested: false)
        if intent.prompt.isEmpty && !intent.contextReferences.isEmpty {
            let mentionNames = intent.contextReferences.map(\.rawValue).joined(separator: ", ")
            let instruction = "请分析并总结上述附加的 \(mentionNames) 上下文。请指出关键信息、执行状态或潜在问题，并提示我可进行的相关操作。"
            return instruction + "\n\n" + attachments.joined(separator: "\n\n")
        }
        return result + "\n\n" + attachments.joined(separator: "\n\n")
    }
}
