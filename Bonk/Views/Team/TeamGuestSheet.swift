import SwiftUI
import Network

struct TeamGuestSheet: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceManager.self) private var workspace
    @ObservedObject var discovery: TeamDiscoveryService
    @ObservedObject var relay: TeamRelay

    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var pinInput = ""
    @State private var displayName = ""
    @State private var selectedHost: DiscoveredTeamHost?
    @State private var showPinPrompt = false

    private var savedDisplayName: String {
        if let saved = UserDefaults.standard.string(forKey: "team_display_name"), !saved.trimmingCharacters(in: .whitespaces).isEmpty {
            return saved
        }
        let full = NSFullUserName()
        if !full.isEmpty { return full }
        return Host.current().localizedName ?? "Guest"
    }
    private func persistDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: "team_display_name")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppStyle.spacingM) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: AppStyle.fontMedium, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: AppStyle.iconHero, height: AppStyle.iconHero)
                Text(i18n.t(.joinSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: ""))
                    .font(.system(size: AppStyle.fontRegular, weight: .semibold))
                Spacer()
                if relay.isConnected {
                    Text(i18n.t(.connected))
                        .font(.caption)
                        .padding(.horizontal, AppStyle.spacingS).padding(.vertical, AppStyle.spacingXS)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(AppStyle.cornerRadiusSmall)
                }
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingML)
            Divider()
            Form {
                Section(i18n.t(.discovered)) {
                    let filteredHosts = discovery.discoveredHosts.filter { host in
                        guard relay.isHosting, let hostName = relay.hostPeer?.displayName else { return true }
                        return host.displayName != hostName
                    }
                    if filteredHosts.isEmpty {
                        Text(i18n.t(.noHostsFound))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredHosts) { host in
                            HStack(spacing: AppStyle.spacingM) {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.secondary)
                                Text(host.displayName).lineLimit(1)
                                Spacer()
                                if selectedHost?.id == host.id {
                                    Button(i18n.t(.connected)) {
                                        showPinPrompt = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.green)
                                } else {
                                    Button(i18n.t(.selectHost)) {
                                        selectedHost = host
                                        manualHost = ""
                                        manualPort = ""
                                        pinInput = ""
                                        showPinPrompt = true
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                if relay.isConnected {
                    Section {
                        HStack {
                            Label("已连接", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("打开实时终端") {
                                workspace.isTeamWindowOpen = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    Section {
                        HStack {
                            Spacer()
                            Button(i18n.t(.disconnect), role: .destructive) { relay.disconnectGuest() }
                                .buttonStyle(.bordered)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section(i18n.t(.manualIP)) {
                        TextField("Host", text: $manualHost)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                        TextField(i18n.t(.port), text: $manualPort)
                    }
                    .onChange(of: manualHost) { _, _ in if !manualHost.isEmpty { selectedHost = nil } }

                    Section(i18n.t(.joinSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")) {
                        TextField(i18n.t(.displayName), text: $displayName)
                        TextField("PIN", text: $pinInput)
                        HStack {
                            Spacer()
                            Button {
                                joinSelectedHost()
                            } label: {
                                Label(i18n.t(.joinSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: ""), systemImage: "arrow.right.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(!canJoin)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: AppStyle.spacingS, leading: 0, bottom: AppStyle.spacingS, trailing: 0))
                    }
                }
            }
            .formStyle(.grouped)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: AppStyle.panelWidthMedium)
        .onAppear {
            if displayName.trimmingCharacters(in: .whitespaces).isEmpty { displayName = savedDisplayName }
            discovery.startBrowsing()
        }
        .onDisappear { discovery.stopBrowsing() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(i18n.t(.cancel)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.ok)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .alert(i18n.t(.connectionError), isPresented: Binding(get: { relay.lastError != nil }, set: { if !$0 { relay.lastError = nil } })) {
            Button(i18n.t(.ok)) { relay.lastError = nil }
        } message: {
            Text(relay.lastError ?? "")
        }
        .alert("输入 PIN", isPresented: $showPinPrompt) {
            SecureField("PIN", text: $pinInput)
                .textContentType(.oneTimeCode)
            Button(i18n.t(.joinSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")) {
                joinSelectedHost()
            }
            .disabled(pinInput.count != TeamConstants.pairingPinLength)
            Button(i18n.t(.cancel), role: .cancel) { pinInput = "" }
        } message: {
            if let host = selectedHost {
                Text("连接到 \(host.displayName) 需要输入主持端显示的 6 位 PIN")
            } else {
                Text("请输入主持端显示的 6 位 PIN")
            }
        }
    }

    private var canJoin: Bool {
        pinInput.count == TeamConstants.pairingPinLength && (!manualHost.isEmpty || selectedHost != nil)
    }

    private func joinSelectedHost() {
        let endpoint: NWEndpoint
        if let host = selectedHost {
            endpoint = host.endpoint
        } else {
            guard let portValue = UInt16(manualPort) else {
                relay.lastError = i18n.t(.invalidPort)
                return
            }
            if manualHost.trimmingCharacters(in: .whitespaces).isEmpty {
                relay.lastError = i18n.t(.connectionError)
                return
            }
            endpoint = discovery.manualEndpoint(host: manualHost, port: portValue)
        }
        let effective = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? savedDisplayName : displayName
        persistDisplayName(effective)
        relay.connectToHost(endpoint: endpoint, displayName: effective, pin: pinInput)
    }
}
