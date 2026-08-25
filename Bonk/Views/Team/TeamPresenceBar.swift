import SwiftUI

struct TeamPresenceBar: View {
    @Environment(I18n.self) private var i18n
    var snapshot: TeamPresenceSnapshot?

    var body: some View {
        if let snapshot {
            HStack(spacing: 8) {
                peerBadge(peer: snapshot.hostPeer, isHost: true)
                ForEach(snapshot.guestPeers) { guest in
                    peerBadge(peer: guest, isHost: false)
                }
                if let driverID = snapshot.driverPeerID,
                   let driver = snapshot.allPeers.first(where: { $0.id == driverID }) {
                    let isHost = driverID == snapshot.hostPeer.id
                    Text("● \(driver.displayName) \(isHost ? i18n.t(.hostControls) : i18n.t(.driver))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
    }

    private func peerBadge(peer: TeamPeer, isHost: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(peer.isDriver ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(peer.displayName)
                .font(.caption)
                .lineLimit(1)
            if isHost {
                Text(i18n.t(.hostSession))
                    .font(.caption2)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.blue.opacity(0.15))
                    .cornerRadius(4)
            }
            if peer.isDriver {
                Image(systemName: "keyboard.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(6)
    }
}
