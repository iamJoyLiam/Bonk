import SwiftUI
import Network

struct TeamGuestSheet: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var discovery: TeamDiscoveryService
    @ObservedObject var relay: TeamRelay

    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var pinInput = ""
    @State private var displayName = ""
    @State private var selectedHost: DiscoveredTeamHost?
    @State private var guestOutput = ""

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
                                let effective = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? (Host.current().localizedName ?? "Guest") : displayName
                                relay.sendControlRequest(displayName: effective, peerID: UUID())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                            Text(relay.driverPeerID == nil ? i18n.t(.hostControls) : "Driver: \(relay.driverPeerID?.uuidString.prefix(4) ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        GuestInputBar(relay: relay)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: AppStyle.panelWidthMedium)
        .onAppear { discovery.startBrowsing() }
        .onDisappear { discovery.stopBrowsing() }
        .onReceive(NotificationCenter.default.publisher(for: .teamGuestDidReceiveOutput)) { note in
            if let payload = note.userInfo?["payload"] as? String {
                guestOutput.append(payload)
                if guestOutput.count > 20000 { guestOutput = String(guestOutput.suffix(15000)) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(i18n.t(.cancel)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.ok)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
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
            guard let portValue = UInt16(manualPort) else { return }
            endpoint = discovery.manualEndpoint(host: manualHost, port: portValue)
        }
        let effective = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? (Host.current().localizedName ?? "Guest") : displayName
        relay.connectToHost(endpoint: endpoint, displayName: effective, pin: pinInput)
    }
}

private struct GuestInputBar: View {
    @Environment(I18n.self) private var i18n
    @ObservedObject var relay: TeamRelay
    @State private var inputText = ""

    var body: some View {
        HStack(spacing: AppStyle.spacingM) {
            TextField(i18n.t(.typeCommand), text: $inputText)
                .onSubmit { sendInput() }
            Button(i18n.t(.send)) { sendInput() }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.isEmpty)
        }
    }

    private func sendInput() {
        guard !inputText.isEmpty else { return }
        relay.sendInputFromGuest(inputText + "\n")
        inputText = ""
    }
}
