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
                    submitAgentTask(text: pendingText, ssh: ssh)
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
            guard let ssh = sshService else {
                engine.agentMessages = [AgentMessage(
                    role: .system, content: i18n.t(.noSSHConnectionAgent)
                )]
                return
            }
            submitAgentTask(text: text, ssh: ssh)
        case .host(let hostID):
            guard let host = hosts.first(where: { $0.id == hostID }) else { return }
            if connectionService.connectedHostID == hostID {
                Task {
                    do {
                        let ssh = try await connectionService.service(for: host)
                        submitAgentTask(text: text, ssh: ssh)
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

    private func submitAgentTask(text: String, ssh: SSHNetworkService) {
        if currentConversation == nil { createNewConversation() }
        let conversation = currentConversation

        inputText = ""
        wasCancelled = false
        engine.isProcessing = true

        currentTask?.cancel()
        currentTask = Task {
            await engine.runAgent(
                input: text, sshService: ssh,
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
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(targetStateText)
                    .font(.system(size: 10))
                    .foregroundStyle(targetStateColor)
            }

            Spacer()

            targetActionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlColor).opacity(0.5))
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
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
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
                        .font(.system(size: 10))
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
                        .font(.system(size: 10))
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
                        .font(.system(size: 10))
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
