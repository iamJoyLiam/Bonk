import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query private var allPreferences: [UserPreferences]
    @StateObject private var themeManager = TerminalThemeManager.shared

    @State private var sessionManager = SessionManager()
    #if os(macOS)
        @State private var workspace = WorkspaceManager()
        @State private var showInspector = false
        @State private var sftpWindow: NSWindow?
    #endif

    private var preferences: UserPreferences {
        allPreferences.first ?? UserPreferences()
    }

    private func ensurePreferences() {
        if allPreferences.isEmpty {
            modelContext.insert(UserPreferences())
        }
    }

    private var colorScheme: TerminalColorScheme {
        themeManager.resolve()
    }

    var body: some View {
        Group {
            #if os(macOS)
                macOSLayout
            #else
                iOSLayout
            #endif
        }
        .environment(\.locale, Locale(identifier: i18n.lang))
        #if os(macOS)
            .environment(workspace)
        #endif
        .onAppear {
            ensurePreferences()
            AIDataMigration.migrateIfNeeded(context: modelContext)
            sessionManager.setModelContext(modelContext)
        }
        .alert(i18n.t(.connectionError), isPresented: $sessionManager.showError) {
            Button(i18n.t(.ok)) {}
        } message: {
            Text(sessionManager.lastError ?? i18n.t(.unknownError))
        }
        // Menu bar notification bridges
        .onReceive(NotificationCenter.default.publisher(for: .menuCloseTab)) { _ in
            if let id = sessionManager.activeTabID {
                Task { await sessionManager.closeTab(id) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuNewTerminal)) { _ in
            workspace.isAddHostPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuConnect)) { _ in
            workspace.isSessionManagerPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuDisconnect)) { _ in
            if let id = sessionManager.activeTabID {
                Task { await sessionManager.disconnectTab(id) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuReconnect)) { _ in
            if let id = sessionManager.activeTabID {
                Task { await sessionManager.reconnectTab(id) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuToggleSFTP)) { _ in
            toggleSFTPWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuToggleAI)) { _ in
            workspace.toggleRightPanel(.ai)
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShowSerialPort)) { _ in
            workspace.isSerialPortPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShowSnippets)) { _ in
            workspace.snippetsHistoryTab = .snippets
            workspace.activeRightPanel = .snippetsHistory
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShowPortForwarding)) { _ in
            workspace.isPortForwardingPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShowCommandHistory)) { _ in
            workspace.snippetsHistoryTab = .history
            workspace.activeRightPanel = .snippetsHistory
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuChangeTheme)) { notification in
            if let themeID = notification.object as? String {
                themeManager.setActive(themeID)
            }
        }
    }

    // MARK: - macOS Layout (2-column NavigationSplitView + .inspector)

    #if os(macOS)
        private var macOSLayout: some View {
            NavigationSplitView {
                HostListView(
                    sessionManager: sessionManager,
                    defaultPort: preferences.defaultPort
                )
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } detail: {
                TerminalTabView(
                    sessionManager: sessionManager,
                    colorScheme: colorScheme,
                    cursorStyle: themeManager.cursorStyle,
                    cursorBlink: themeManager.cursorBlink
                )
                .background(colorScheme.isTransparent ? Color.clear : Color(nsColor: .controlBackgroundColor))
                .clipped()
                .inspector(isPresented: $showInspector) {
                    InspectorContainerView(sessionManager: sessionManager)
                }
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar {
                // [📶] [🔌] [🔀] [⏱] — .principal tracks content column boundary
                ToolbarItem(placement: .principal) {
                    ControlGroup {
                        Button { workspace.toggleBroadcast() } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(
                                    workspace.isBroadcastEnabled ? .orange : .primary
                                )
                        }
                        .opacity(workspace.isBroadcastEnabled ? 1.0 : 0.8)

                        Button { workspace.isSerialPortPresented = true } label: {
                            Image(systemName: "cable.connector")
                        }
                        Button { workspace.isPortForwardingPresented = true } label: {
                            Image(systemName: "arrow.triangle.branch")
                        }
                        Button { workspace.isSessionManagerPresented = true } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }

                // [📁] — .principal tracks content column boundary
                ToolbarItem(placement: .principal) {
                    ControlGroup {
                        Button { toggleSFTPWindow() } label: {
                            Image(systemName: "folder.fill")
                        }
                    }
                }

                // [✨] [📝]
                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        Button { workspace.toggleRightPanel(.ai) } label: {
                            Image(systemName: "sparkles")
                        }
                        Button { workspace.toggleRightPanel(.snippetsHistory) } label: {
                            Image(systemName: "text.badge.plus")
                        }
                    }
                }
            }
            // Sync inspector state
            .onChange(of: workspace.activeRightPanel) { _, newValue in
                showInspector = newValue != .none
            }
            .onChange(of: showInspector) { _, isOpen in
                if !isOpen { workspace.activeRightPanel = .none }
            }
            // SFTP independent window
            .onChange(of: workspace.isSFTPWindowOpen) { _, isOpen in
                if isOpen { openSFTPWindow() }
            }
            // Sheets
            .sheet(isPresented: $workspace.isSerialPortPresented) {
                SerialPortView(isPresented: $workspace.isSerialPortPresented, onConnect: { _ in })
                    .environment(i18n)
            }
            .sheet(isPresented: $workspace.isPortForwardingPresented) {
                PortForwardView(isPresented: $workspace.isPortForwardingPresented, sshService: sessionManager.activeTab?.session?.sshService)
                    .environment(i18n)
            }
            .sheet(isPresented: $workspace.isSessionManagerPresented) {
                SessionManagerView(isPresented: $workspace.isSessionManagerPresented, onConnect: { _ in })
                    .environment(i18n)
            }
        }
    #endif

    // MARK: - SFTP Window

    private func toggleSFTPWindow() {
        #if os(macOS)
            if let window = sftpWindow, window.isVisible {
                window.close()
            } else {
                openSFTPWindow()
            }
        #endif
    }

    private func openSFTPWindow() {
        #if os(macOS)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = i18n.t(.sftpBrowser)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SFTPWindowView(sessionManager: sessionManager)
                    .environment(i18n)
                    .environment(workspace)
            )
            window.center()
            window.makeKeyAndOrderFront(nil)
            let delegate = SFTPWindowDelegate { self.sftpWindow = nil }
            window.delegate = delegate
            sftpWindow = window
        #endif
    }

    // MARK: - iOS Layout

    private var iOSLayout: some View {
        NavigationStack {
            HostListView(sessionManager: sessionManager, defaultPort: preferences.defaultPort)
                .navigationTitle("Bonk")
                .navigationDestination(for: UUID.self) { tabID in
                    if let tab = sessionManager.tabs.first(where: { $0.id == tabID }) {
                        iOSTerminalDetail(tab)
                    }
                }
        }
    }

    private func iOSTerminalDetail(_ tab: TerminalTab) -> some View {
        TerminalTabContentView(
            tab: tab,
            colorScheme: colorScheme,
            fontSize: preferences.fontSize,
            fontFamily: preferences.fontFamily,
            lineHeight: preferences.lineHeight,
            scrollbackLines: preferences.scrollbackLines,
            cursorStyle: themeManager.cursorStyle,
            cursorBlink: themeManager.cursorBlink,
            copyOnSelect: preferences.copyOnSelect,
            onSend: { data in Task { try? await sessionManager.sendInput(data, to: tab.id) } },
            onResize: { cols, rows in Task { try? await sessionManager.resizePTY(cols: cols, rows: rows, tabID: tab.id) } },
            onTitleChange: { sessionManager.updateTabTitle($0, tabID: tab.id) },
            onReconnect: { Task { await sessionManager.reconnectTab(tab.id) } }
        )
        .navigationTitle(tab.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { Task { await sessionManager.reconnectTab(tab.id) } } label: {
                        Label(i18n.t(.reconnect), systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) { Task { await sessionManager.closeTab(tab.id) } } label: {
                        Label(i18n.t(.disconnect), systemImage: "bolt.slash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

// MARK: - SFTP Window Delegate

#if os(macOS)
    private final class SFTPWindowDelegate: NSObject, NSWindowDelegate {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_ notification: Notification) {
            onClose()
        }
    }
#endif
