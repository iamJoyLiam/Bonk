import SwiftUI

// MARK: - Typing Indicator (three pulsing dots)

struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0 ..< 3, id: \.self) { index in
                    let delay = Double(index) * 0.2
                    let progress = ((time + delay) * 2).truncatingRemainder(dividingBy: 2.0)
                    let scale = progress < 1.0
                        ? 0.5 + 0.5 * sin(progress * .pi)
                        : 0.5 + 0.5 * sin((2.0 - progress) * .pi)
                    Circle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 6, height: 6)
                        .scaleEffect(scale)
                }
            }
        }
        .frame(width: 26, height: 10)
    }
}

// MARK: - Chat Bubbles

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
            Text(i18n.t(.agentMode))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(i18n.t(.agentModeDesc))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Regular Bubbles

    func bubble(_ msg: AIMessageRecord) -> some View {
        VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
            Text(msg.timestamp, style: .time)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            if msg.role == .assistant {
                HStack(alignment: .top, spacing: 8) {
                    avatar("sparkles")
                    MarkdownTextView(content: msg.content, sshService: sshService)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Spacer()
                    Text(msg.content)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    avatar("person.fill")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
    }

    func streamingBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            avatar("sparkles")
            MarkdownTextView(content: text, sshService: sshService)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var loadingBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar("sparkles")
            TypingIndicator()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    var stoppedIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "stop.circle")
                .font(.system(size: 11))
            Text(i18n.t(.aiStopped))
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Agent Bubbles

    func agentBubble(_ msg: AgentMessage) -> some View {
        VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
            Text(msg.timestamp, style: .time)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            HStack(alignment: .top, spacing: 8) {
                switch msg.role {
                case .user:
                    agentUserContent(msg)
                case .assistant:
                    agentAssistantContent(msg)
                case .commandOutput:
                    agentCommandOutputContent(msg)
                case .system:
                    agentSystemContent(msg)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
    }

    private func agentUserContent(_ msg: AgentMessage) -> some View {
        Group {
            Spacer()
            Text(msg.content)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            avatar("person.fill")
        }
    }

    private func agentAssistantContent(_ msg: AgentMessage) -> some View {
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
                MarkdownTextView(content: msg.content, sshService: sshService)
                if let command = msg.command, !command.isEmpty {
                    agentCommandBlock(command)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func agentCommandOutputContent(_ msg: AgentMessage) -> some View {
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlColor).opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func agentSystemContent(_ msg: AgentMessage) -> some View {
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Plan Approval

    func agentPlanApprovalView(_ plan: AgentPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            planHeaderView(plan)
            ForEach(plan.steps) { step in planStepRow(step) }
            planActionButtons
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func planHeaderView(_ plan: AgentPlan) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(.blue)
            Text("Execution Plan").font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("\(plan.steps.count) steps").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func planStepRow(_ step: AgentPlan.Step) -> some View {
        let (icon, color): (String, Color) = switch step.riskLevel {
        case .safe: ("checkmark.circle", .green)
        case .moderate: ("exclamationmark.triangle", .orange)
        case .dangerous: ("exclamationmark.octagon", .red)
        case .blocked: ("xmark.shield", .gray)
        }
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.description).font(.system(size: 11))
                Text(step.command).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var planActionButtons: some View {
        HStack(spacing: 8) {
            Button { engine.approvePlan() } label: {
                Label("Execute Plan", systemImage: "play.fill")
                    .font(.system(size: 11))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15)).clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Button { engine.rejectPlan() } label: {
                Label(i18n.t(.cancel), systemImage: "xmark")
                    .font(.system(size: 11))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color(nsColor: .controlColor)).clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Confirmation Banner

    func agentConfirmationBanner(_ pending: PendingCommand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                let icon = pending.riskLevel == .dangerous ? "exclamationmark.octagon" : "exclamationmark.triangle"
                Image(systemName: icon)
                    .foregroundStyle(pending.riskLevel == .dangerous ? .red : .orange)
                Text(pending.riskLevel == .dangerous ? "Dangerous Command" : "Confirm Command")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(pending.command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 8) {
                Button {
                    pending.continuation(true)
                    engine.pendingConfirmation = nil
                } label: {
                    Label(i18n.t(.execute), systemImage: "play.fill")
                        .font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    pending.continuation(false)
                    engine.pendingConfirmation = nil
                } label: {
                    Label(i18n.t(.cancel), systemImage: "xmark")
                        .font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color(nsColor: .controlColor))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(pending.riskLevel == .dangerous ? Color.red.opacity(0.08) : Color.orange.opacity(0.08))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Avatar

    func avatar(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Color(nsColor: .controlColor))
            .clipShape(Circle())
    }
}
