import SwiftUI

/// Transparent status overlay for Team terminal — shows network, typing, participant count at top-right.
struct TeamStatusOverlay: View {
    @ObservedObject var relay: TeamRelay

    private var isActive: Bool {
        relay.isHosting || relay.isConnected
    }

    private var participantText: String {
        // Host counts as 1 + guests
        let total = relay.connectedPeers.count + 1
        let max = TeamConstants.maxGuestCount + 1
        return "\(total)/\(max)人"
    }

    private var networkColor: Color {
        if relay.isHosting {
            return relay.connectedPeers.isEmpty ? .secondary : .green
        } else if relay.isConnected {
            // Guest: check last activity
            let interval = Date().timeIntervalSince(relay.guestLastActivity)
            if interval < 5 { return .green }
            if interval < 15 { return .yellow }
            return .orange
        } else {
            return .gray
        }
    }

    private var networkIcon: String {
        if relay.isHosting {
            return relay.connectedPeers.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right"
        } else {
            return relay.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
        }
    }

    var body: some View {
        if isActive {
            HStack(spacing: 8) {
                // Network + participants
                HStack(spacing: 4) {
                    Image(systemName: networkIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(networkColor)
                    Text(participantText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let typingName = relay.typingPeerName {
                    Divider().frame(height: 12)
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("\(typingName) 正在输入…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        }
    }
}
