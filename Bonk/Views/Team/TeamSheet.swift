import SwiftUI
import Network

struct TeamSheet: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var relay: TeamRelay
    @ObservedObject var discovery: TeamDiscoveryService

    @State private var selectedTab: String = "host"
    @State private var hostDisplayName = Host.current().localizedName ?? "Mac"
    @State private var guestDisplayName = Host.current().localizedName ?? "Guest"
    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var pinInput = ""
    @State private var selectedHost: DiscoveredTeamHost?
    @State private var guestOutput = ""

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            Picker("", selection: $selectedTab) {
                Text(i18n.t(.hostSession)).tag("host")
                Text(i18n.t(.joinSession)).tag("join")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppStyle.spacingL)
            .padding(.vertical, AppStyle.spacingM)

            ScrollView {
                VStack(spacing: AppStyle.spacingL) {
                    if selectedTab == "host" { hostContent }
                    else { joinContent }
                }
                .padding(.horizontal, AppStyle.spacingL)
                .padding(.vertical, AppStyle.spacingM)
            }
            Divider()
            footerSection
        }
        .frame(minWidth: AppStyle.settingsWindowWidth, idealWidth: AppStyle.settingsWindowWidth)
        .frame(maxHeight: 600)
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

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: AppStyle.spacingM) {
            Image(systemName: "person.2.fill")
                .font(.system(size: AppStyle.fontMedium, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: AppStyle.iconHero, height: AppStyle.iconHero)
                .background(Circle().fill(Color.blue.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(i18n.t(.team))
                    .font(.system(size: AppStyle.fontRegular, weight: .semibold))
                Text(i18n.t(.teamHostHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if relay.isHosting || relay.isConnected {
                Text(relay.isHosting ? i18n.t(.hostSession) : i18n.t(.connected))
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingM)
    }

    // MARK: - Host

    private var hostContent: some View {
        VStack(spacing: AppStyle.spacingL) {
            if relay.isHosting, let pin = relay.pairingPin, let port = relay.hostedPort {
                GroupBox {
                    VStack(spacing: AppStyle.spacingM) {
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
                }
                Text("Guest: Bonk → Team → PIN")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { relay.stopHosting() } label: {
                    Label(i18n.t(.stopHosting), systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                GroupBox {
                    VStack(alignment: .leading, spacing: AppStyle.spacingM) {
                        Text(i18n.t(.displayName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(i18n.t(.displayName), text: $hostDisplayName)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            relay.startHosting(displayName: hostDisplayName)
                        } label: {
                            Label(i18n.t(.startHosting), systemImage: "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }

            GroupBox(i18n.t(.connectedPeers)) {
                if relay.connectedPeers.isEmpty {
                    Text(i18n.t(.noGuests))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: AppStyle.spacingS) {
                        ForEach(relay.connectedPeers) { peer in
                            HStack(spacing: AppStyle.spacingM) {
                                Image(systemName: "person.circle.fill")
                                    .foregroundStyle(.secondary)
                                Text(peer.displayName)
                                    .lineLimit(1)
                                Spacer()
                                if relay.driverPeerID == peer.id {
                                    Label("Driver", systemImage: "keyboard.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                } else {
                                    Button(i18n.t(.grantControl)) { relay.grantControl(to: peer.id) }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                                Button(i18n.t(.revokeControl)) { relay.revokeControl(from: peer.id) }
                                    .font(.caption)
                            }
                            .padding(.vertical, 2)
                            if peer.id != relay.connectedPeers.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Join

    private var joinContent: some View {
        VStack(spacing: AppStyle.spacingL) {
            GroupBox(i18n.t(.discovered)) {
                if discovery.discoveredHosts.isEmpty {
                    Text(i18n.t(.noHostsFound))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(discovery.discoveredHosts) { host in
                            HStack(spacing: AppStyle.spacingM) {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.secondary)
                                Text(host.displayName)
                                    .lineLimit(1)
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
                            .padding(.vertical, AppStyle.spacingS)
                            if host.id != discovery.discoveredHosts.last?.id { Divider() }
                        }
                    }
                }
            }

            GroupBox(i18n.t(.manualIP)) {
                HStack(spacing: AppStyle.spacingM) {
                    TextField("192.168.1.10", text: $manualHost)
                        .textFieldStyle(.roundedBorder)
                    TextField(i18n.t(.port), text: $manualPort)
                        .frame(maxWidth: 90)
                        .textFieldStyle(.roundedBorder)
                }
                .onChange(of: manualHost) { _, _ in if !manualHost.isEmpty { selectedHost = nil } }
            }

            GroupBox {
                VStack(spacing: AppStyle.spacingM) {
                    TextField(i18n.t(.displayName), text: $guestDisplayName)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: AppStyle.spacingM) {
                        TextField("PIN", text: $pinInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                        Button {
                            joinSelectedHost()
                        } label: {
                            Label(i18n.t(.joinSession), systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canJoin)
                        Spacer()
                    }
                    if relay.isConnected {
                        Button(i18n.t(.disconnect), role: .destructive) { relay.disconnectGuest() }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if relay.isConnected {
                GroupBox(i18n.t(.liveTerminal)) {
                    ScrollView {
                        Text(guestOutput.isEmpty ? i18n.t(.waitingForOutput) : guestOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(6)
                    }
                    .frame(height: 140)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                }
                HStack(spacing: AppStyle.spacingM) {
                    Button(i18n.t(.requestControl)) {
                        relay.sendControlRequest(displayName: guestDisplayName, peerID: UUID())
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
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendGuestInput() }
                    Button(i18n.t(.send)) { sendGuestInput() }
                        .buttonStyle(.borderedProminent)
                        .disabled(guestInputText.isEmpty)
                }
            }
        }
    }

    @State private var guestInputText = ""
    private func sendGuestInput() {
        guard !guestInputText.isEmpty else { return }
        relay.sendInputFromGuest(guestInputText + "\n")
        guestInputText = ""
    }

    private var footerSection: some View {
        HStack {
            Button(i18n.t(.ok)) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingM)
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
        relay.connectToHost(endpoint: endpoint, displayName: guestDisplayName, pin: pinInput)
    }
}
