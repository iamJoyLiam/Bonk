import SwiftUI

struct TeamHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var relay: TeamRelay
    @State private var displayName = Host.current().localizedName ?? "Mac"

    var body: some View {
        VStack(spacing: 16) {
            headerSection
            Divider()
            if relay.isHosting, let pin = relay.pairingPin, let port = relay.hostedPort {
                hostingSection(pin: pin, port: port)
            } else {
                setupSection
            }
            Divider()
            peersSection
            Spacer()
            footerSection
        }
        .frame(minWidth: 380, minHeight: 420)
        .padding()
    }

    private var headerSection: some View {
        HStack {
            Image(systemName: "person.2.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            Text("Host Team Session")
                .font(.headline)
            Spacer()
        }
    }

    private var setupSection: some View {
        VStack(spacing: 12) {
            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)
            Button {
                relay.startHosting(displayName: displayName)
            } label: {
                Label("Start Hosting", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text("Shares current terminal tab with LAN peers. Guest connects via Bonjour or IP:port + PIN.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func hostingSection(pin: String, port: UInt16) -> some View {
        VStack(spacing: 12) {
            GroupBox {
                VStack(spacing: 8) {
                    LabeledContent("PIN") {
                        Text(pin)
                            .font(.system(.title2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Port") { Text("\(port)") }
                    LabeledContent("Service") { Text(TeamConstants.serviceType) }
                }
            }
            Text("Guest: Bonk → Team → Join → enter PIN")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) { relay.stopHosting() } label: {
                Label("Stop Hosting", systemImage: "stop.circle")
            }
        }
    }

    private var peersSection: some View {
        GroupBox("Connected") {
            if relay.connectedPeers.isEmpty {
                Text("No guests yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(relay.connectedPeers) { peer in
                        HStack {
                            Text(peer.displayName).lineLimit(1)
                            Spacer()
                            if relay.driverPeerID == peer.id {
                                Text("Driver").font(.caption2).foregroundStyle(.green)
                            } else {
                                Button("Grant Control") { relay.grantControl(to: peer.id) }
                                    .font(.caption)
                            }
                            Button("Revoke") { relay.revokeControl(from: peer.id) }
                                .font(.caption)
                        }
                    }
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
}
