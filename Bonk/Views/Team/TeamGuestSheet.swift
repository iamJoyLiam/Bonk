import SwiftUI
import Network

struct TeamGuestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var discovery: TeamDiscoveryService
    @ObservedObject var relay: TeamRelay

    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var pinInput = ""
    @State private var displayName = Host.current().localizedName ?? "Guest"
    @State private var selectedHost: DiscoveredTeamHost?
    @State private var guestOutput = ""

    var body: some View {
        VStack(spacing: 16) {
            headerSection
            Divider()
            discoveredSection
            Divider()
            manualSection
            Divider()
            pinSection
            if relay.isConnected {
                Divider()
                GroupBox("Live Terminal") {
                    ScrollView {
                        Text(guestOutput.isEmpty ? "Waiting for output…" : guestOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                }
                HStack(spacing: 8) {
                    Button("Request Control") {
                        relay.sendControlRequest(displayName: displayName, peerID: UUID())
                    }
                    Spacer()
                    Text(relay.driverPeerID == nil ? "Host controls" : "Driver: \(relay.driverPeerID?.uuidString.prefix(4) ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                GuestInputBar(relay: relay)
            }
            Spacer()
            footerSection
        }
        .frame(minWidth: 400, minHeight: 460)
        .padding()
        .onAppear { discovery.startBrowsing() }
        .onDisappear { discovery.stopBrowsing() }
        .onReceive(NotificationCenter.default.publisher(for: .teamGuestDidReceiveOutput)) { note in
            if let payload = note.userInfo?["payload"] as? String {
                guestOutput.append(payload)
                if guestOutput.count > 20000 { guestOutput = String(guestOutput.suffix(15000)) }
            }
        }
    }

    private var headerSection: some View {
        HStack {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.green)
            Text("Join Team Session")
                .font(.headline)
            Spacer()
            if relay.isConnected {
                Text("Connected")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(4)
            }
        }
    }

    private var discoveredSection: some View {
        GroupBox("Discovered (Bonjour)") {
            if discovery.discoveredHosts.isEmpty {
                Text("No hosts found on LAN")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(discovery.discoveredHosts) { host in
                        HStack {
                            Text(host.displayName).lineLimit(1)
                            Spacer()
                            Button(selectedHost?.id == host.id ? "Selected" : "Select") {
                                selectedHost = host
                                manualHost = ""
                                manualPort = ""
                            }
                            .disabled(selectedHost?.id == host.id)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var manualSection: some View {
        GroupBox("Manual IP") {
            HStack(spacing: 8) {
                TextField("192.168.1.10", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                TextField("port", text: $manualPort)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }
            .onChange(of: manualHost) { _, _ in if !manualHost.isEmpty { selectedHost = nil } }
        }
    }

    private var pinSection: some View {
        GroupBox("Join") {
            VStack(spacing: 8) {
                TextField("Display name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField("6-digit PIN", text: $pinInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                    Button {
                        joinSelectedHost()
                    } label: {
                        Label("Join", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canJoin)
                }
                if relay.isConnected {
                    Button("Disconnect", role: .destructive) { relay.disconnectGuest() }
                }
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
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
            guard let portValue = UInt16(manualPort) else { return }
            endpoint = discovery.manualEndpoint(host: manualHost, port: portValue)
        }
        relay.connectToHost(endpoint: endpoint, displayName: displayName, pin: pinInput)
    }
}

private struct GuestInputBar: View {
    @ObservedObject var relay: TeamRelay
    @State private var inputText = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Type command…", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { sendInput() }
            Button("Send") { sendInput() }
                .disabled(inputText.isEmpty)
        }
    }

    private func sendInput() {
        guard !inputText.isEmpty else { return }
        relay.sendInputFromGuest(inputText + "\n")
        inputText = ""
    }
}
