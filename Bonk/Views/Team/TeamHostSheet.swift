import SwiftUI

private func hostLocalIPAddress() -> String {
    var address = "127.0.0.1"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        let addrFamily = interface.ifa_addr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) {
            let name = String(validatingCString: interface.ifa_name) ?? ""
            if name == "en0" || name == "en1" || name.hasPrefix("en") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(decoding: hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !ip.hasPrefix("127.") { address = ip; break }
            }
        }
    }
    freeifaddrs(ifaddr)
    return address
}

struct TeamHostSheet: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var relay: TeamRelay
    @State private var displayName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppStyle.spacingM) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: AppStyle.fontMedium, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: AppStyle.iconHero, height: AppStyle.iconHero)
                Text(i18n.t(.hostSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: ""))
                    .font(.system(size: AppStyle.fontRegular, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingML)
            Divider()
            Form {
                if relay.isHosting, let pin = relay.pairingPin, let port = relay.hostedPort {
                    Section(i18n.t(.hostSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")) {
                        LabeledContent("IP") {
                            Text(hostLocalIPAddress())
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("PIN") {
                            Text(pin)
                                .font(.system(.title3, design: .monospaced, weight: .semibold))
                                .textSelection(.enabled)
                        }
                        LabeledContent(i18n.t(.port)) { Text(verbatim: "\(port)") }
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
                    }
                } else {
                    Section(i18n.t(.hostSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")) {
                        TextField(i18n.t(.displayName), text: $displayName)
                        HStack {
                            Spacer()
                            Button {
                                let effective = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? (Host.current().localizedName ?? "Mac") : displayName
                                relay.startHosting(displayName: effective)
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
                                    Label(i18n.t(.driver), systemImage: "keyboard.fill")
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
        .alert(i18n.t(.controlRequestTitle), isPresented: Binding(get: { relay.pendingControlRequest != nil }, set: { if !$0 { relay.pendingControlRequest = nil } })) {
            Button(i18n.t(.allow)) { if let req = relay.pendingControlRequest { relay.grantControl(to: req.peerID) } }
            Button(i18n.t(.deny), role: .cancel) { relay.pendingControlRequest = nil }
        } message: {
            if let req = relay.pendingControlRequest {
                Text(i18n.tr(.controlRequestMessage, args: req.displayName))
            }
        }
    }
}
