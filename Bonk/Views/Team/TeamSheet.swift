import SwiftUI
import Network

private func localIPAddress() -> String {
    var address = "127.0.0.1"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        let addrFamily = interface.ifa_addr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            if name == "en0" || name == "en1" || name.hasPrefix("en") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if !ip.hasPrefix("127.") {
                    address = ip
                    break
                }
            }
        }
    }
    freeifaddrs(ifaddr)
    return address
}

struct TeamSheet: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceManager.self) private var workspace
    @ObservedObject var relay: TeamRelay
    @ObservedObject var discovery: TeamDiscoveryService

    @State private var selectedTab: String = "host"
    @State private var cachedIP: String = "127.0.0.1"
    @State private var hostDisplayName = ""
    @State private var guestDisplayName = ""
    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var pinInput = ""
    @State private var selectedHost: DiscoveredTeamHost?
    @State private var showPinPrompt = false
    @State private var showShareHosts = false
    @State private var maxGuests: Int = TeamConstants.maxGuestCount

    private var savedDisplayName: String {
        if let saved = UserDefaults.standard.string(forKey: "team_display_name"), !saved.trimmingCharacters(in: .whitespaces).isEmpty {
            return saved
        }
        let full = NSFullUserName()
        if !full.isEmpty {
            return full
        }
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
        .onAppear {
            cachedIP = localIPAddress()
            maxGuests = TeamConstants.maxGuestCount
            if hostDisplayName.trimmingCharacters(in: .whitespaces).isEmpty { hostDisplayName = savedDisplayName }
            if guestDisplayName.trimmingCharacters(in: .whitespaces).isEmpty { guestDisplayName = savedDisplayName }
            if selectedTab == "join" { discovery.startBrowsing() }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == "join" { discovery.startBrowsing() } else { discovery.stopBrowsing() }
        }
        .onChange(of: relay.isHosting) { _, isHosting in
            if isHosting { cachedIP = localIPAddress() }
        }
        .onDisappear { discovery.stopBrowsing() }
        .alert(i18n.t(.connectionError), isPresented: Binding(get: { relay.lastError != nil }, set: { if !$0 { relay.lastError = nil } })) {
            Button(i18n.t(.ok)) { relay.lastError = nil }
        } message: {
            Text(relay.lastError ?? "")
        }
        .alert(i18n.t(.controlRequestTitle), isPresented: Binding(get: { relay.pendingControlRequest != nil }, set: { if !$0 { relay.pendingControlRequest = nil } })) {
            Button(i18n.t(.allow)) { if let req = relay.pendingControlRequest { relay.grantControl(to: req.peerID) } }
            Button(i18n.t(.deny), role: .cancel) { relay.pendingControlRequest = nil }
        } message: {
            if let req = relay.pendingControlRequest {
                Text(i18n.tr(.controlRequestMessage, args: req.displayName))
            }
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

    // MARK: - Host (Form)

    @ViewBuilder
    private var hostForm: some View {
        if relay.isHosting, let pin = relay.pairingPin {
            Section(i18n.t(.hostSession).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")) {
                LabeledContent("IP") {
                    Text(cachedIP)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("PIN") {
                    Text(pin)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                }
                LabeledContent(i18n.t(.port)) {
                    if let port = relay.hostedPort {
                        Text(verbatim: "\(port)")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("Service") {
                    Text(TeamConstants.serviceType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("人数上限") {
                HStack {
                    Text("最大访客数")
                    Spacer()
                    Stepper(value: $maxGuests, in: 1...8) {
                        Text("\(maxGuests) 人")
                    }
                    .frame(width: 140)
                    .onChange(of: maxGuests) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "team_max_guests")
                    }
                }
                Text("当前 \(relay.connectedPeers.count) / \(maxGuests) 人在线，超限时访客将收到“已达上限”提示，主持端不弹。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if BonkAppDelegate.shared?.sessionManager?.activeTab == nil {
                Section {
                    Label("主持端尚未打开终端，访客将看不到内容。请先新建或连接一个主机标签。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .listRowBackground(Color.orange.opacity(0.08))
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
                        guard BonkAppDelegate.shared?.sessionManager?.activeTab != nil else {
                            relay.lastError = "请先打开一个终端再开启主持"
                            return
                        }
                        let effectiveName = hostDisplayName.trimmingCharacters(in: .whitespaces).isEmpty ? savedDisplayName : hostDisplayName
                        persistDisplayName(effectiveName)
                        relay.startHosting(displayName: effectiveName)
                    } label: {
                        Label(i18n.t(.startHosting), systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(BonkAppDelegate.shared?.sessionManager?.activeTab == nil)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: AppStyle.spacingS, leading: 0, bottom: AppStyle.spacingS, trailing: 0))
            }
        }

        Section(i18n.t(.connectedPeers)) {
            if !relay.isHosting {
                if relay.isConnected {
                    Text("当前为访客模式，已连接到主持端，无法主持")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(i18n.t(.noGuests))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if relay.connectedPeers.isEmpty {
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
                                .disabled(relay.sharedSessionID == nil)
                        }
                        Button(i18n.t(.revokeControl)) { relay.revokeControl(from: peer.id) }
                            .font(.caption)
                    }
                }
            }
            if relay.isHosting, !relay.connectedPeers.isEmpty {
                Section {
                    Button {
                        showShareHosts = true
                    } label: {
                        Label("分享已保存主机给访客", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showShareHosts) {
            TeamShareHostsSheet(relay: relay)
        }
    }

    // MARK: - Join (Form)

    @ViewBuilder
    private var joinForm: some View {
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
                        .font(.callout)
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
            }
        }
    }

    private var canJoin: Bool {
        pinInput.count == TeamConstants.pairingPinLength && (!manualHost.isEmpty || selectedHost != nil)
    }

    private func joinSelectedHost() {
        let endpoint: NWEndpoint
        if let host = selectedHost { endpoint = host.endpoint }
        else {
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
        let effectiveGuestName = guestDisplayName.trimmingCharacters(in: .whitespaces).isEmpty ? savedDisplayName : guestDisplayName
        persistDisplayName(effectiveGuestName)
        relay.connectToHost(endpoint: endpoint, displayName: effectiveGuestName, pin: pinInput)
    }
}
