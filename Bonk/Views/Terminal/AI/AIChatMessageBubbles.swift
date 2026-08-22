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
                        .fill(Color.secondary.opacity(AppStyle.opacityPressed))
                        .frame(width: AppStyle.statusDotSmall, height: AppStyle.statusDotSmall)
                        .scaleEffect(scale)
                }
            }
        }
        .frame(width: AppStyle.size26, height: 10)
    }
}

// MARK: - Chat Bubbles

extension AIChatSidebarView {
    var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: AppStyle.fontXXL))
                .foregroundStyle(.tertiary)
            Text(i18n.t(.terminalAssistant))
                .font(.system(size: AppStyle.fontRegular))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppStyle.spacingTop)
    }

    var agentEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: AppStyle.fontXXL))
                .foregroundStyle(.tertiary)
            Text(i18n.t(.agentMode))
                .font(.system(size: AppStyle.fontRegular, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(i18n.t(.agentModeDesc))
                .font(.system(size: AppStyle.fontBody))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppStyle.spacingTop)
    }

    // MARK: - Regular Bubbles

    func bubble(_ msg: AIMessageRecord) -> some View {
        VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
            Text(msg.timestamp, style: .time)
                .font(.system(size: AppStyle.fontCaption))
                .foregroundStyle(.tertiary)

            if msg.role == .assistant {
                HStack(alignment: .top, spacing: 8) {
                    avatar("sparkles")
                    MarkdownTextView(
                        content: msg.content,
                        onRun: { code in sessionManager.sendTextToActiveTab(code) }
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Spacer()
                    Text(msg.content)
                        .font(.system(size: AppStyle.fontRegular))
                        .textSelection(.enabled)
                        .padding(.horizontal, AppStyle.spacingL)
                        .padding(.vertical, AppStyle.spacingM)
                        .background(Color.accentColor.opacity(AppStyle.opacityStroke))
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
            MarkdownTextView(
                content: text,
                onRun: { code in sessionManager.sendTextToActiveTab(code) }
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var loadingBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar("sparkles")
            TypingIndicator()
                .padding(.horizontal, AppStyle.spacingL)
                .padding(.vertical, AppStyle.spacingM)
        }
    }

    var stoppedIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "stop.circle")
                .font(.system(size: AppStyle.fontSmall))
            Text(i18n.t(.aiStopped))
                .font(.system(size: AppStyle.fontSmall))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingXS)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Agent Bubbles

    func agentBubble(_ msg: AgentMessage) -> some View {
        VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
            Text(msg.timestamp, style: .time)
                .font(.system(size: AppStyle.fontCaption))
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
                .font(.system(size: AppStyle.fontRegular))
                .textSelection(.enabled)
                .padding(.horizontal, AppStyle.spacingL)
                .padding(.vertical, AppStyle.spacingM)
                .background(Color.accentColor.opacity(AppStyle.opacityStroke))
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
                            .font(.system(size: AppStyle.fontSmall))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(i18n.t(.thinking), systemImage: "brain")
                            .font(.system(size: AppStyle.fontSmall))
                            .foregroundStyle(.tertiary)
                    }
                }
                if !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownTextView(
                        content: msg.content,
                        onRun: { code in sessionManager.sendTextToActiveTab(code) }
                    )
                }
                if let command = msg.command, !command.isEmpty {
                    agentCommandBlock(command)
                }
            }
            .padding(.horizontal, AppStyle.spacingL)
            .padding(.vertical, AppStyle.spacingM)
            .background(Color(nsColor: .controlColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func agentCommandOutputContent(_ msg: AgentMessage) -> some View {
        Group {
            avatar("terminal")
            VStack(alignment: .leading, spacing: 0) {
                // Header: command + status icon + duration
                HStack(spacing: 6) {
                    if let command = msg.command, !command.isEmpty {
                        Text("$ \(command)")
                            .font(.system(size: AppStyle.fontSmall, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(i18n.t(.output))
                            .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                    }
                    Spacer()
                    if let status = msg.status {
                        Image(systemName: status.icon)
                            .font(.system(size: AppStyle.fontSmallest))
                            .foregroundStyle(status.color)
                    }
                    if let duration = msg.duration {
                        Text(String(format: "%.1fs", duration))
                            .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppStyle.spacingML)
                .padding(.vertical, AppStyle.spacingS)
                .background(Color(nsColor: .controlColor).opacity(AppStyle.opacityDisabled))

                // Output body
                if !msg.content.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(msg.content)
                            .font(.system(size: AppStyle.fontSmall, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, AppStyle.spacingML)
                            .padding(.vertical, AppStyle.spacingM)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(AppStyle.opacityBackgroundStrong), lineWidth: 1)
            )
        }
    }

    private func agentSystemContent(_ msg: AgentMessage) -> some View {
        Group {
            if msg.content.hasPrefix("Running:") {
                // In-flight command notice: compact blue bar, command in mono.
                let command = msg.content
                    .dropFirst("Running:".count)
                    .trimmingCharacters(in: .whitespaces)
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: AppStyle.fontTiny))
                        .foregroundStyle(.blue)
                    Text("$ \(command)")
                        .font(.system(size: AppStyle.fontSmall, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, AppStyle.spacingML)
                .padding(.vertical, AppStyle.spacingSPlus)
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(AppStyle.opacityOverlayFaint))
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: AppStyle.fontSmall))
                    Text(msg.content)
                        .font(.system(size: AppStyle.fontBody))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppStyle.spacingL)
                .padding(.vertical, AppStyle.spacingS)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(AppStyle.opacityOverlaySubtle))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func agentCommandBlock(_ command: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: AppStyle.fontCaption))
                .foregroundStyle(.secondary)
            Text(command)
                .font(.system(size: AppStyle.fontBody, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(AppStyle.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlColor).opacity(AppStyle.opacityPressed))
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall))
    }

    // MARK: - Plan Approval

    func agentPlanApprovalView(_ plan: AgentPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            planHeaderView(plan)
            ForEach(plan.steps) { step in planStepRow(step) }
            planActionButtons
        }
        .padding(AppStyle.spacingML)
        .background(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium).fill(Color.blue.opacity(AppStyle.opacityBackgroundSubtle)))
        .padding(.horizontal, AppStyle.spacingL).padding(.vertical, AppStyle.spacingXS)
    }

    private func planHeaderView(_ plan: AgentPlan) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(.blue)
            Text(i18n.t(.executionPlan)).font(.system(size: AppStyle.fontBody, weight: .semibold))
            Spacer()
            let stepsCount = String(format: i18n.t(.stepsCount), plan.steps.count)
            Text(stepsCount)
                .font(.system(size: AppStyle.fontCaption))
                .foregroundStyle(.tertiary)
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
            Image(systemName: icon).font(.system(size: AppStyle.fontCaption)).foregroundStyle(color).frame(width: AppStyle.iconXL)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.description).font(.system(size: AppStyle.fontSmall))
                Text(step.command).font(.system(size: AppStyle.fontCaption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var planActionButtons: some View {
        HStack(spacing: 8) {
            Button { engine.approvePlan() } label: {
                Label(i18n.t(.executePlan), systemImage: "play.fill")
                    .font(.system(size: AppStyle.fontSmall))
                    .padding(.horizontal, AppStyle.spacingML).padding(.vertical, AppStyle.spacingXS)
                    .background(Color.accentColor.opacity(AppStyle.opacityBackgroundLight)).clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Button { engine.rejectPlan() } label: {
                Label(i18n.t(.cancel), systemImage: "xmark")
                    .font(.system(size: AppStyle.fontSmall))
                    .padding(.horizontal, AppStyle.spacingML).padding(.vertical, AppStyle.spacingXS)
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
                Text(pending.riskLevel == .dangerous ? i18n.t(.dangerousCommand) : i18n.t(.confirmCommand))
                    .font(.system(size: AppStyle.fontBody, weight: .semibold))
            }
            Text(pending.command)
                .font(.system(size: AppStyle.fontBody, design: .monospaced))
                .textSelection(.enabled)
                .padding(AppStyle.spacingS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlColor).opacity(AppStyle.opacityDisabled))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 8) {
                Button {
                    pending.continuation(true)
                    engine.pendingConfirmation = nil
                } label: {
                    Label(i18n.t(.execute), systemImage: "play.fill")
                        .font(.system(size: AppStyle.fontSmall))
                        .padding(.horizontal, AppStyle.spacingML).padding(.vertical, AppStyle.spacingXS)
                        .background(Color.accentColor.opacity(AppStyle.opacityBackgroundLight))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    pending.continuation(false)
                    engine.pendingConfirmation = nil
                } label: {
                    Label(i18n.t(.cancel), systemImage: "xmark")
                        .font(.system(size: AppStyle.fontSmall))
                        .padding(.horizontal, AppStyle.spacingML).padding(.vertical, AppStyle.spacingXS)
                        .background(Color(nsColor: .controlColor))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppStyle.spacingML)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium)
                .fill(pending.riskLevel == .dangerous ? Color.red.opacity(AppStyle.opacityStroke) : Color.orange.opacity(AppStyle.opacityStroke))
        )
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingXS)
    }

    // MARK: - Avatar

    func avatar(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: AppStyle.fontCaption))
            .foregroundStyle(.secondary)
            .frame(width: AppStyle.size22, height: AppStyle.size22)
            .background(Color(nsColor: .controlColor))
            .clipShape(Circle())
    }
}
