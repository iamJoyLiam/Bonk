import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query private var allPreferences: [UserPreferences]
    @StateObject private var themeManager = TerminalThemeManager.shared

    @State private var sessionManager = SessionManager()
    @State private var appStore = AppStore.shared
    #if os(macOS)
        @State private var workspace = WorkspaceManager()
        @State private var showInspector = false
        @State private var showAddHostSheet = false
        @State private var showTerminalSearch = false
        @State private var showQuickConnect = false
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
                AIProviderStore.shared.setModelContext(modelContext)
                sessionManager.broadcastManager = workspace.broadcastManager
                TerminalViewCache.shared.configureMemoryPressure {
                    sessionManager.activeTabID
                }
            }
            .alert(i18n.t(.connectionError), isPresented: $sessionManager.showError) {
                Button(i18n.t(.ok)) {}
            } message: {
                Text(sessionManager.lastError ?? i18n.t(.unknownError))
            }
            .modifier(MenuActionsModifier(
                sessionManager: sessionManager,
                workspace: workspace,
                appStore: appStore,
                themeManager: themeManager,
                showAddHostSheet: $showAddHostSheet,
                showTerminalSearch: $showTerminalSearch,
                showQuickConnect: $showQuickConnect
            ))
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
                    cursorBlink: themeManager.cursorBlink,
                    showSearch: $showTerminalSearch
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
            .onReceive(NotificationCenter.default.publisher(for: .toggleSFTP)) { _ in
                toggleSFTPWindow()
            }
            // Sheets
            .sheet(isPresented: $showQuickConnect) {
                QuickConnectView(
                    sessionManager: sessionManager,
                    isPresented: $showQuickConnect,
                    defaultPort: preferences.defaultPort
                )
                .environment(i18n)
            }
            .sheet(isPresented: $showAddHostSheet) {
                NavigationStack {
                    AddHostSheet(defaultPort: preferences.defaultPort) { host in
                        modelContext.insert(host)
                    }
                    .environment(i18n)
                }
            }
            .sheet(isPresented: $workspace.isSerialPortPresented) {
                SerialPortView(isPresented: $workspace.isSerialPortPresented, onConnect: { _ in })
                    .environment(i18n)
            }
            .sheet(isPresented: $workspace.isPortForwardingPresented) {
                PortForwardView(
                    isPresented: $workspace.isPortForwardingPresented,
                    sshService: sessionManager.activeTab?.session?.sshService
                )
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
                    .modelContext(modelContext)
            )
            window.center()
            window.makeKeyAndOrderFront(nil)
            let delegate = SFTPWindowDelegate { sftpWindow = nil }
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

// MARK: - Menu Actions Modifier

#if os(macOS)
    private struct MenuActionsModifier: ViewModifier {
        let sessionManager: SessionManager
        let workspace: WorkspaceManager
        let appStore: AppStore
        let themeManager: TerminalThemeManager
        @Binding var showAddHostSheet: Bool
        @Binding var showTerminalSearch: Bool
        @Binding var showQuickConnect: Bool

        func body(content: Content) -> some View {
            content
                .modifier(SessionMenuActions(sessionManager: sessionManager, showAddHostSheet: $showAddHostSheet))
                .modifier(WorkspaceMenuActions(workspace: workspace, showQuickConnect: $showQuickConnect))
                .modifier(AppMenuActions(appStore: appStore, themeManager: themeManager, showTerminalSearch: $showTerminalSearch))
        }
    }

    private struct SessionMenuActions: ViewModifier {
        let sessionManager: SessionManager
        @Binding var showAddHostSheet: Bool

        func body(content: Content) -> some View {
            content
                .focusedSceneValue(\.menuCloseTab) {
                    if let id = sessionManager.activeTabID { Task { await sessionManager.closeTab(id) } }
                }
                .focusedSceneValue(\.menuNewTerminal) { showAddHostSheet = true }
                .focusedSceneValue(\.menuDisconnect) {
                    if let id = sessionManager.activeTabID { Task { await sessionManager.disconnectTab(id) } }
                }
                .focusedSceneValue(\.menuReconnect) {
                    if let id = sessionManager.activeTabID { Task { await sessionManager.reconnectTab(id) } }
                }
                .focusedSceneValue(\.menuSplitHorizontal) { sessionManager.splitHorizontal() }
                .focusedSceneValue(\.menuSplitVertical) { sessionManager.splitVertical() }
                .focusedSceneValue(\.menuClosePane) { sessionManager.closePane() }
        }
    }

    private struct WorkspaceMenuActions: ViewModifier {
        let workspace: WorkspaceManager
        @Binding var showQuickConnect: Bool

        func body(content: Content) -> some View {
            content
                .focusedSceneValue(\.menuToggleSFTP) {
                    NotificationCenter.default.post(name: .toggleSFTP, object: nil)
                }
                .focusedSceneValue(\.menuToggleAI) { workspace.toggleRightPanel(.ai) }
                .focusedSceneValue(\.menuToggleAITerminal) {
                    NotificationCenter.default.post(name: .toggleAIChat, object: nil)
                }
                .focusedSceneValue(\.menuShowSerialPort) { workspace.isSerialPortPresented = true }
                .focusedSceneValue(\.menuShowSnippets) {
                    workspace.snippetsHistoryTab = .snippets
                    workspace.activeRightPanel = .snippetsHistory
                }
                .focusedSceneValue(\.menuShowPortForwarding) { workspace.isPortForwardingPresented = true }
                .focusedSceneValue(\.menuShowCommandHistory) {
                    workspace.snippetsHistoryTab = .history
                    workspace.activeRightPanel = .snippetsHistory
                }
                .focusedSceneValue(\.menuQuickConnect) { showQuickConnect = true }
        }
    }

    private struct AppMenuActions: ViewModifier {
        let appStore: AppStore
        let themeManager: TerminalThemeManager
        @Binding var showTerminalSearch: Bool

        func body(content: Content) -> some View {
            content
                .focusedSceneValue(\.menuChangeTheme) { themeID in themeManager.setActive(themeID) }
                .focusedSceneValue(\.menuFind) {
                    appStore.dispatch(.toggleSearch)
                    showTerminalSearch = appStore.uiState.showSearch
                }
        }
    }
#endif

// MARK: - SFTP Window Delegate

#if os(macOS)
    private final class SFTPWindowDelegate: NSObject, NSWindowDelegate {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_: Notification) {
            onClose()
        }
    }
#endif
