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
        Group {
            if msg.role == .assistant {
                MarkdownTextView(
                    content: msg.content,
                    onRun: { code in sessionManager.sendTextToActiveTab(code) }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Spacer(minLength: AppStyle.spacingXXL)
                    Text(msg.content)
                        .font(.system(size: AppStyle.fontRegular))
                        .textSelection(.enabled)
                        .padding(.horizontal, AppStyle.spacingML)
                        .padding(.vertical, AppStyle.spacingM)
                        .background(Color.accentColor.opacity(AppStyle.opacityBackgroundStrong))
                        .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
                        )
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    func streamingBubble(_ text: String) -> some View {
        MarkdownTextView(
            content: text,
            onRun: { code in sessionManager.sendTextToActiveTab(code) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var loadingBubble: some View {
        HStack(spacing: AppStyle.spacingM) {
            TypingIndicator()
            Spacer()
        }
        .padding(.vertical, AppStyle.spacingS)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var stoppedIndicator: some View {
        HStack(spacing: AppStyle.spacingS) {
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
        Group {
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

    private func agentUserContent(_ msg: AgentMessage) -> some View {
        HStack {
            Spacer(minLength: AppStyle.spacingXXL)
            Text(msg.content)
                .font(.system(size: AppStyle.fontRegular))
                .textSelection(.enabled)
                .padding(.horizontal, AppStyle.spacingML)
                .padding(.vertical, AppStyle.spacingM)
                .background(Color.accentColor.opacity(AppStyle.opacityBackgroundStrong))
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func agentAssistantContent(_ msg: AgentMessage) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.spacingS) {
            if let thinking = msg.thinking, !thinking.isEmpty {
                DisclosureGroup {
                    Text(thinking)
                        .font(.system(size: AppStyle.fontSmall))
                        .foregroundStyle(.secondary)
                        .padding(.top, AppStyle.spacingXXS)
                } label: {
                    Label(i18n.t(.thinking), systemImage: "brain")
                        .font(.system(size: AppStyle.fontSmall, weight: .medium))
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func agentCommandOutputContent(_ msg: AgentMessage) -> some View {
        AgentToolExecutionCard(msg: msg)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func agentSystemContent(_ msg: AgentMessage) -> some View {
        Group {
            if msg.content.hasPrefix("Running:") {
                EmptyView()
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
}

// MARK: - Agent Tool Execution Card (Auto-collapsible Codex/Cursor style)

struct AgentToolExecutionCard: View {
    let msg: AgentMessage
    @State private var isExpanded: Bool
    @State private var isCopied = false

    init(msg: AgentMessage) {
        self.msg = msg
        // Auto-expand failed, blocked or running commands; auto-collapse successful ones
        _isExpanded = State(initialValue: msg.status == .failed || msg.status == .blocked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clickable header row
            Button {
                if msg.status != .running && !msg.content.isEmpty {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if msg.status == .running {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.65)
                    } else if let status = msg.status {
                        Image(systemName: status.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(status.color)
                    }

                    if let command = msg.command, !command.isEmpty {
                        Text(command)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Terminal Command")
                            .font(.system(size: 12, weight: .medium))
                    }

                    Spacer()

                    if let duration = msg.duration {
                        Text(String(format: "%.1fs", duration))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    if msg.status != .running && !msg.content.isEmpty {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Collapsible stdout block
            if isExpanded && !msg.content.isEmpty {
                Divider().opacity(0.3)
                ZStack(alignment: .topTrailing) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(msg.content)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.7))

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(msg.content, forType: .string)
                        isCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            isCopied = false
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            if isCopied {
                                Text("Copied").font(.system(size: 9))
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
    }
}
