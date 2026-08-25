import SwiftUI
import Network

struct TeamSheet: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var relay: TeamRelay
    @ObservedObject var discovery: TeamDiscoveryService

    @State private var selectedTab: String = "host"
    @State private var hostDisplayName = ""
    @State private var guestDisplayName = ""
    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var pinInput = ""
    @State private var selectedHost: DiscoveredTeamHost?
    @State private var guestOutput = ""
    @State private var guestInputText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppStyle.spacingM) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: AppStyle.fontMedium, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: AppStyle.iconHero, height: AppStyle.iconHero)
                Text(i18n.t(.team))
                    .font(.system(size: AppStyle.fontRegular, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingML)
            Divider()
            Form {
                Section {
                    HStack {
                        Spacer()
                        Picker("", selection: $selectedTab) {
                            Text(i18n.t(.hostSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")).tag("host")
                            Text(i18n.t(.joinSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")).tag("join")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: AppStyle.teamPickerWidth)
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: AppStyle.spacingM, leading: 0, bottom: AppStyle.spacingS, trailing: 0))

                if selectedTab == "host" { hostForm }
                else { joinForm }

                Section {
                    Text(i18n.t(.teamHostHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            .formStyle(.grouped)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: AppStyle.panelWidthMedium)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(i18n.t(.cancel)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.ok)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { if selectedTab == "join" { discovery.startBrowsing() } }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == "join" { discovery.startBrowsing() } else { discovery.stopBrowsing() }
        }
        .onDisappear { discovery.stopBrowsing() }
        .onReceive(NotificationCenter.default.publisher(for: .teamGuestDidReceiveOutput)) { note in
            if let payload = note.userInfo?["payload"] as? String {
                guestOutput.append(payload)
                if guestOutput.count > 20000 { guestOutput = String(guestOutput.suffix(15000)) }
            }
        }
    }

    // MARK: - Host (Form)

    @ViewBuilder
    private var hostForm: some View {
        if relay.isHosting, let pin = relay.pairingPin, let port = relay.hostedPort {
            Section(i18n.t(.hostSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")) {
                LabeledContent("PIN") {
                    Text(pin)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                }
                LabeledContent(i18n.t(.port)) { Text("\(port)") }
                LabeledContent("Service") {
                    Text(TeamConstants.serviceType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button(role: .destructive) { relay.stopHosting() } label: {
                        Label(i18n.t(.stopHosting), systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: AppStyle.spacingS, leading: 0, bottom: AppStyle.spacingS, trailing: 0))
            }
        } else {
            Section(i18n.t(.hostSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")) {
                TextField(i18n.t(.displayName), text: $hostDisplayName)
                HStack {
                    Spacer()
                    Button {
                        let effectiveName = hostDisplayName.trimmingCharacters(in: .whitespaces).isEmpty ? (Host.current().localizedName ?? "Mac") : hostDisplayName
                        relay.startHosting(displayName: effectiveName)
                    } label: {
                        Label(i18n.t(.startHosting), systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: AppStyle.spacingS, leading: 0, bottom: AppStyle.spacingS, trailing: 0))
            }
        }

        Section(i18n.t(.connectedPeers)) {
            if relay.connectedPeers.isEmpty {
                Text(i18n.t(.noGuests))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(relay.connectedPeers) { peer in
                    HStack(spacing: AppStyle.spacingM) {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.secondary)
                        Text(peer.displayName).lineLimit(1)
                        Spacer()
                        if relay.driverPeerID == peer.id {
                            Label("Driver", systemImage: "keyboard.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Button(i18n.t(.grantControl)) { relay.grantControl(to: peer.id) }
                                .font(.caption)
                        }
                        Button(i18n.t(.revokeControl)) { relay.revokeControl(from: peer.id) }
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Join (Form)

    @ViewBuilder
    private var joinForm: some View {
        Section(i18n.t(.discovered)) {
            if discovery.discoveredHosts.isEmpty {
                Text(i18n.t(.noHostsFound))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discovery.discoveredHosts) { host in
                    HStack(spacing: AppStyle.spacingM) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.secondary)
                        Text(host.displayName).lineLimit(1)
                        Spacer()
                        Button(selectedHost?.id == host.id ? i18n.t(.connected) : i18n.t(.selectHost)) {
                            selectedHost = host
                            manualHost = ""
                            manualPort = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedHost?.id == host.id)
                    }
                }
            }
        }

        Section(i18n.t(.manualIP)) {
            TextField("Host", text: $manualHost)
                .autocorrectionDisabled()
                .textContentType(.URL)
            TextField(i18n.t(.port), text: $manualPort)
        }
        .onChange(of: manualHost) { _, _ in if !manualHost.isEmpty { selectedHost = nil } }

        Section(i18n.t(.joinSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")) {
            TextField(i18n.t(.displayName), text: $guestDisplayName)
            TextField("PIN", text: $pinInput)
            HStack {
                Spacer()
                Button {
                    joinSelectedHost()
                } label: {
                    Label(i18n.t(.joinSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: ""), systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canJoin)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: AppStyle.spacingS, leading: 0, bottom: AppStyle.spacingS, trailing: 0))
            if relay.isConnected {
                HStack {
                    Spacer()
                    Button(i18n.t(.disconnect), role: .destructive) { relay.disconnectGuest() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }

        if relay.isConnected {
            Section(i18n.t(.liveTerminal)) {
                ScrollView {
                    Text(guestOutput.isEmpty ? i18n.t(.waitingForOutput) : guestOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(AppStyle.spacingS)
                }
                .frame(height: AppStyle.teamLiveTerminalHeight)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(AppStyle.cornerRadiusSmall)
                .listRowInsets(EdgeInsets())
            }
            Section {
                HStack(spacing: AppStyle.spacingM) {
                    Button(i18n.t(.requestControl)) {
                        let effective = guestDisplayName.trimmingCharacters(in: .whitespaces).isEmpty ? (Host.current().localizedName ?? "Guest") : guestDisplayName
                        relay.sendControlRequest(displayName: effective, peerID: UUID())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Text(relay.driverPeerID == nil ? i18n.t(.hostControls) : "Driver")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: AppStyle.spacingM) {
                    TextField(i18n.t(.typeCommand), text: $guestInputText)
                        .onSubmit { sendGuestInput() }
                    Button(i18n.t(.send)) { sendGuestInput() }
                        .buttonStyle(.borderedProminent)
                        .disabled(guestInputText.isEmpty)
                }
            }
        }
    }

    private func sendGuestInput() {
        guard !guestInputText.isEmpty else { return }
        relay.sendInputFromGuest(guestInputText + "\n")
        guestInputText = ""
    }

    private var canJoin: Bool {
        pinInput.count == TeamConstants.pairingPinLength && (!manualHost.isEmpty || selectedHost != nil)
    }

    private func joinSelectedHost() {
        let endpoint: NWEndpoint
        if let host = selectedHost { endpoint = host.endpoint }
        else {
            guard let portValue = UInt16(manualPort) else { return }
            endpoint = discovery.manualEndpoint(host: manualHost, port: portValue)
        }
        let effectiveGuestName = guestDisplayName.trimmingCharacters(in: .whitespaces).isEmpty ? (Host.current().localizedName ?? "Guest") : guestDisplayName
        relay.connectToHost(endpoint: endpoint, displayName: effectiveGuestName, pin: pinInput)
    }
}
