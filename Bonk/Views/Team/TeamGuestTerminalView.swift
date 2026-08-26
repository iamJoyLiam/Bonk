import SwiftUI
import SwiftTerm
import Combine
import AppKit

struct TeamGuestTerminalView: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceManager.self) private var workspace
    @ObservedObject var relay: TeamRelay
    @State private var hasReceivedOutput = false
    @State private var showControlRequested = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部状态栏：无气泡、无撑大，原样文本+图标（替换 toolbar 气泡方案）
            HStack(spacing: 6) {
                Image(systemName: relay.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(relay.isConnected ? .green : .secondary)
                Text(relay.isConnected ? i18n.t(.connected) : i18n.t(.disconnected))
                    .font(.caption)
                    .foregroundStyle(relay.isConnected ? .green : .secondary)
                Spacer()
                if showControlRequested {
                    Text("已发送请求…").font(.caption2).foregroundStyle(.secondary)
                }
                Button(i18n.t(.requestControl)) {
                    let saved = UserDefaults.standard.string(forKey: "team_display_name")
                    let effective: String
                    if let s = saved, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                        effective = s
                    } else {
                        let full = NSFullUserName()
                        effective = full.isEmpty ? (Host.current().localizedName ?? "Guest") : full
                    }
                    relay.sendControlRequest(displayName: effective)
                    showControlRequested = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showControlRequested = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!relay.isConnected || relay.sharedSessionID == nil || (relay.driverPeerID != nil && relay.driverPeerID != relay.hostPeerID))
                .help(relay.sharedSessionID == nil ? "主持端暂无可共享的终端" : "")
                Text((relay.driverPeerID == nil || relay.driverPeerID == relay.hostPeerID) ? "未授权" : i18n.t(.driver))
                    .font(.caption)
                    .foregroundStyle((relay.driverPeerID == nil || relay.driverPeerID == relay.hostPeerID) ? Color.red : Color.green)
                    .padding(.horizontal, AppStyle.spacingS)
                    .padding(.vertical, AppStyle.spacingXS)
                    .background(((relay.driverPeerID == nil || relay.driverPeerID == relay.hostPeerID) ? Color.red.opacity(0.12) : Color.green.opacity(0.15)))
                    .clipShape(.rect(cornerRadius: AppStyle.cornerRadiusSmall))
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, 8)
            Divider()
            ZStack {
                TeamGuestFullTerminalBridge(relay: relay)
                    .frame(minHeight: 320, idealHeight: 400)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: AppStyle.cornerRadiusSmall))
                    .overlay(alignment: .topTrailing) {
                        TeamStatusOverlay(relay: relay)
                            .padding(.top, 6)
                            .padding(.trailing, 8)
                    }
            }
            .padding(AppStyle.spacingXL)
            .overlay {
                if !relay.isConnected && !hasReceivedOutput {
                    Text(i18n.t(.waitingForOutput))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(i18n.t(.disconnect), role: .destructive) {
                    relay.disconnectGuest()
                    workspace.isTeamWindowOpen = false
                    dismiss()
                }
                Button(i18n.t(.close)) {
                    workspace.isTeamWindowOpen = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingM)
        }
        .frame(minWidth: 600, minHeight: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .teamGuestDidReceiveOutput)) { note in
            if note.userInfo?["payload"] as? String != nil {
                hasReceivedOutput = true
            }
        }
    }
}

#if os(macOS)
import AppKit

struct TeamGuestTerminalPanel: View {
    @ObservedObject var relay: TeamRelay

    var body: some View {
        TeamGuestFullTerminalBridge(relay: relay)
            .frame(minHeight: AppStyle.teamLiveTerminalHeight)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(.rect(cornerRadius: AppStyle.cornerRadiusSmall))
    }
}

private struct TeamGuestFullTerminalBridge: NSViewRepresentable {
    @ObservedObject var relay: TeamRelay

    func makeCoordinator() -> Coordinator { Coordinator(relay: relay) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let terminalView = NativeTerminalView(frame: .zero, font: font)
        terminalView.bellStyle = .none
        let scheme = TerminalThemeManager.shared.resolve()
        applyColorScheme(to: terminalView, scheme: scheme)
        terminalView.terminal.changeScrollback(10000)
        // Match host scrollbar: small overlay, hidden until scroll
        for subview in terminalView.subviews {
            if let scroller = subview as? NSScroller {
                scroller.controlSize = .small
                scroller.scrollerStyle = .overlay
                scroller.alphaValue = 0.0
            }
        }
        terminalView.terminalDelegate = context.coordinator
        context.coordinator.terminalView = terminalView
        context.coordinator.start()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Feed replay buffer if already connected
        if relay.isConnected {
            // Small delay to ensure view is in window
            DispatchQueue.main.async {
                terminalView.feed(text: "\r\n[Connected to host]\r\n")
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.relay = relay
        context.coordinator.updateSessionIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate, ObservableObject {
        var relay: TeamRelay
        weak var terminalView: NativeTerminalView?
        private nonisolated(unsafe) var cancellable: AnyCancellable?
        private var pendingBuffer = ""
        private nonisolated(unsafe) var pendingWorkItem: DispatchWorkItem?
        private var lastOutputRevision: UInt64 = 0
        private var lastSessionID: TeamSessionID?

        init(relay: TeamRelay) { self.relay = relay }

        func start() {
            lastSessionID = relay.sharedSessionID
            let snapshot = relay.guestOutputSnapshot()
            lastOutputRevision = snapshot.revision
            if !snapshot.payload.isEmpty {
                terminalView?.feed(text: snapshot.payload)
            }
            cancellable = NotificationCenter.default.publisher(for: .teamGuestDidReceiveOutput)
                .receive(on: RunLoop.main)
                .sink { [weak self] note in
                    guard let payload = note.userInfo?["payload"] as? String else { return }
                    let revision = note.userInfo?["revision"] as? UInt64 ?? 0
                    guard revision > (self?.lastOutputRevision ?? 0) else { return }
                    self?.lastOutputRevision = revision
                    self?.pendingBuffer.append(payload)
                    self?.scheduleFeed()
                }
        }

        func updateSessionIfNeeded() {
            guard lastSessionID != relay.sharedSessionID else { return }
            lastSessionID = relay.sharedSessionID
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
            pendingBuffer.removeAll(keepingCapacity: true)
            terminalView?.terminal.resetToInitialState()
            let snapshot = relay.guestOutputSnapshot()
            lastOutputRevision = snapshot.revision
            if !snapshot.payload.isEmpty {
                terminalView?.feed(text: snapshot.payload)
            }
        }

        private func scheduleFeed() {
            guard pendingWorkItem == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self, let view = self.terminalView, !self.pendingBuffer.isEmpty else {
                    self?.pendingWorkItem = nil
                    return
                }
                let text = self.pendingBuffer
                self.pendingBuffer = ""
                self.pendingWorkItem = nil
                view.feed(text: text)
            }
            pendingWorkItem = item
            DispatchQueue.main.async(execute: item)
        }

        deinit {
            cancellable?.cancel()
            pendingWorkItem?.cancel()
        }

        // TerminalViewDelegate
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let str = String(decoding: data, as: UTF8.self)
            let relay = self.relay
            Task { @MainActor in relay.sendInputFromGuest(str) }
        }
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            relay.sendResizeFromGuest(columns: newCols, rows: newRows)
        }
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(String(decoding: content, as: UTF8.self), forType: .string)
        }
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
        func bell(source: SwiftTerm.TerminalView) {}
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
#endif
