import SwiftUI

struct TeamHostSheet: View {
    @Environment(I18n.self) private var i18n
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
            Text(i18n.t(.hostSession))
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
                Label(i18n.t(.startHosting), systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text(i18n.t(.teamHostHint))
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
                Label(i18n.t(.stopHosting), systemImage: "stop.circle")
            }
        }
    }

    private var peersSection: some View {
        GroupBox(i18n.t(.connectedPeers)) {
            if relay.connectedPeers.isEmpty {
                Text(i18n.t(.noGuests))
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
    }

    private var footerSection: some View {
        HStack {
            Button(i18n.t(.ok)) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
    }
}
