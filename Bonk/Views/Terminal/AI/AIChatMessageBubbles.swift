import SwiftUI

extension AIChatSidebarView {
    var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(i18n.t(.terminalAssistant))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    var agentEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Agent Mode")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Describe a task and I'll execute commands to complete it.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Regular Bubbles (Ask/Edit modes)

    func bubble(_ msg: AIMessageRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.role == .assistant { avatar("sparkles") }
            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
                Text.markdown(msg.content).font(.system(size: 13)).textSelection(.enabled)
            }
            .padding(10)
            .background(msg.role == .user ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlColor))
            .clipShape(.rect(cornerRadius: 10))
            if msg.role == .user { avatar("person.fill") }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
    }

    func streamingBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            avatar("sparkles")
            Text(text).font(.system(size: 13))
                .padding(10)
                .background(Color(nsColor: .controlColor))
                .clipShape(.rect(cornerRadius: 10))
        }
    }

    var loadingBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar("sparkles")
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Thinking...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(nsColor: .controlColor))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    // MARK: - Agent Bubbles

    func agentBubble(_ msg: AgentMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch msg.role {
            case .user: agentUserBubble(msg)
            case .assistant: agentAssistantBubble(msg)
            case .commandOutput: agentOutputBubble(msg)
            case .system: agentSystemBubble(msg)
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
    }

    private func agentUserBubble(_ msg: AgentMessage) -> some View {
        Group {
            Spacer()
            Text(msg.content)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(10)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(.rect(cornerRadius: 10))
            avatar("person.fill")
        }
    }

    private func agentAssistantBubble(_ msg: AgentMessage) -> some View {
        Group {
            avatar("sparkles")
            VStack(alignment: .leading, spacing: 6) {
                if let thinking = msg.thinking, !thinking.isEmpty {
                    DisclosureGroup {
                        Text(thinking)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Thinking", systemImage: "brain")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text.markdown(msg.content)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                if let command = msg.command, !command.isEmpty {
                    agentCommandBlock(command)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlColor))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    private func agentCommandBlock(_ command: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlColor).opacity(0.6))
        .clipShape(.rect(cornerRadius: 6))
    }

    private func agentOutputBubble(_ msg: AgentMessage) -> some View {
        Group {
            avatar("terminal")
            VStack(alignment: .leading, spacing: 4) {
                Text("Output")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(msg.content)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlColor).opacity(0.8))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    private func agentSystemBubble(_ msg: AgentMessage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text(msg.content)
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1))
        .clipShape(.rect(cornerRadius: 8))
    }

    // MARK: - Avatar

    func avatar(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background(Color(nsColor: .controlColor))
            .clipShape(Circle())
    }
}
