import SwiftUI

extension AIChatSidebarView {
    // MARK: - Target Host Bar

    var connectConfirmBinding: Binding<Bool> {
        Binding(
            get: { pendingConnectHost != nil },
            set: { if !$0 { pendingConnectHost = nil } }
        )
    }

    var errorBinding: Binding<Bool> {
        Binding(
            get: { connectError != nil },
            set: { if !$0 { connectError = nil } }
        )
    }

    /// User confirmed connecting to `pendingConnectHost` for AI use.
    func confirmPendingConnect() {
        guard let host = pendingConnectHost else { return }
        pendingConnectHost = nil
        let pendingText = pendingSubmitText
        pendingSubmitText = nil
        Task {
            do {
                let ssh = try await connectionService.service(for: host)
                if let pendingText {
                    submitAgentTask(text: pendingText, ssh: ssh, hostName: hostDisplayName(host))
                }
            } catch {
                connectError = error.localizedDescription
            }
        }
    }

    // MARK: - Agent Submit Routing

    /// Route an agent task to the selected target. Direct hosts connect on
    /// demand (with confirmation) before the tool loop starts.
    func submitAgent(text: String) {
        switch targetStore.target {
        case .activeTab:
            guard let tab, let ssh = tab.session?.sshService else {
                engine.agentMessages = [AgentMessage(
                    role: .system, content: i18n.t(.noSSHConnectionAgent)
                )]
                return
            }
            // v3.3 hybrid: pass TerminalSession so exec reuses multiplexed channel (Native 1000× channel vs 1000× Process)
            submitAgentTask(text: text, ssh: ssh, hybridSession: tab.session, hostName: hostDisplayName(tab.hostItem))
        case .host(let hostID):
            guard let host = hosts.first(where: { $0.id == hostID }) else { return }
            if connectionService.connectedHostID == hostID {
                Task {
                    do {
                        let ssh = try await connectionService.service(for: host)
                        submitAgentTask(text: text, ssh: ssh, hybridSession: nil, hostName: hostDisplayName(host))
                    } catch {
                        engine.agentMessages = [AgentMessage(
                            role: .system,
                            content: "连接失败: \(error.localizedDescription)"
                        )]
                    }
                }
            } else {
                pendingSubmitText = text
                pendingConnectHost = host
            }
        }
    }

    private func submitAgentTask(text: String, ssh: SSHNetworkService, hybridSession: TerminalSession? = nil, hostName: String) {
        if currentConversation == nil { createNewConversation() }
        let conversation = currentConversation

        let expanded = ContextMentionResolver.expandMentions(
            in: text,
            terminalContext: terminalContext,
            tab: tab
        )

        inputText = ""
        wasCancelled = false
        engine.isProcessing = true

        currentTask?.cancel()
        currentTask = Task {
            await engine.runAgent(
                input: expanded, displayInput: text, sshService: ssh, hybridSession: hybridSession, hostName: hostName,
                conversation: conversation, context: modelContext
            )
            engine.isProcessing = false
        }
    }

    var targetBar: some View {
        HStack(spacing: 8) {
            targetMenu

            VStack(alignment: .leading, spacing: 1) {
                Text(targetDisplayName)
                    .font(.system(size: AppStyle.fontSmall, weight: .medium))
                    .lineLimit(1)
                Text(targetStateText)
                    .font(.system(size: AppStyle.fontCaption))
                    .foregroundStyle(targetStateColor)
            }

            Spacer()

            targetActionButton
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingS)
        .background(Color(nsColor: .controlColor).opacity(AppStyle.opacityDisabled))
    }

    private var targetMenu: some View {
        Menu {
            Button {
                targetStore.target = .activeTab
            } label: {
                Label(i18n.t(.aiCurrentSession), systemImage: "terminal")
            }

            if !hosts.isEmpty {
                Divider()
                ForEach(hosts) { host in
                    Button {
                        targetStore.target = .host(host.id)
                    } label: {
                        Label(hostDisplayName(host), systemImage: "server.rack")
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: AppStyle.fontCaption))
                .foregroundStyle(.secondary)
                .frame(width: AppStyle.iconHuge, height: AppStyle.iconHuge)
        }
        .menuStyle(.borderlessButton)
        .disabled(engine.isProcessing)
    }

    @ViewBuilder
    private var targetActionButton: some View {
        switch targetStore.target {
        case .activeTab:
            if let tab, tab.session?.connectionState.isConnected != true {
                Button {
                    Task { await sessionManager.connectTab(tab) }
                } label: {
                    Label(i18n.t(.connect), systemImage: "link")
                        .font(.system(size: AppStyle.fontCaption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        case .host(let hostID):
            if connectionService.connectedHostID == hostID {
                Button {
                    Task { await connectionService.disconnect() }
                } label: {
                    Label(i18n.t(.disconnect), systemImage: "xmark.circle")
                        .font(.system(size: AppStyle.fontCaption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else if let host = hosts.first(where: { $0.id == hostID }) {
                Button {
                    if allowDirectConnect {
                        pendingConnectHost = host
                    } else {
                        connectError = i18n.t(.aiDirectConnectDisabled)
                    }
                } label: {
                    Label(i18n.t(.connect), systemImage: "link")
                        .font(.system(size: AppStyle.fontCaption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var targetDisplayName: String {
        switch targetStore.target {
        case .activeTab:
            guard let tab else { return i18n.t(.noTerminal) }
            return tab.hostItem.name.isEmpty ? tab.hostItem.host : tab.hostItem.name
        case .host(let hostID):
            guard let host = hosts.first(where: { $0.id == hostID }) else {
                return i18n.t(.noTerminal)
            }
            return hostDisplayName(host)
        }
    }

    private var targetStateText: String {
        switch targetStore.target {
        case .activeTab:
            guard let state = tab?.session?.connectionState else { return i18n.t(.disconnected) }
            return stateText(for: state)
        case .host(let hostID):
            if connectionService.connectedHostID == hostID { return i18n.t(.connected) }
            if connectionService.isConnecting {
                return String(format: i18n.t(.connectingTo), targetDisplayName)
            }
            return i18n.t(.disconnected)
        }
    }

    private func stateText(for state: SSHConnectionState) -> String {
        return switch state {
        case .connected: i18n.t(.connected)
        case .connecting: String(format: i18n.t(.connectingTo), targetDisplayName)
        case .reconnecting: i18n.t(.reconnectingPlain)
        case .disconnected: i18n.t(.disconnected)
        }
    }

    private var targetStateColor: Color {
        switch targetStore.target {
        case .activeTab:
            return switch tab?.session?.connectionState {
            case .connected: .green
            case .connecting, .reconnecting: .orange
            default: .secondary
            }
        case .host(let hostID):
            if connectionService.connectedHostID == hostID { return .green }
            if connectionService.isConnecting { return .orange }
            return .secondary
        }
    }

    private func hostDisplayName(_ host: HostItem) -> String {
        host.name.isEmpty ? host.host : host.name
    }
}
