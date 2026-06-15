import SwiftData
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.modelContext) private var modelContext
    @Query private var allPreferences: [UserPreferences]
    @StateObject private var themeManager = TerminalThemeManager.shared

    @State private var sessionManager = SessionManager()
    #if os(macOS)
        @State private var workspace = WorkspaceManager()
        @State private var showInspector = false
        @State private var sftpWindow: NSWindow?
    #endif

    /// Singleton pattern: ensurePreferences() runs in onAppear, fallback is transient.
    private var preferences: UserPreferences {
        allPreferences.first ?? UserPreferences()
    }

    private func ensurePreferences() {
        if allPreferences.isEmpty {
            modelContext.insert(UserPreferences())
        }
    }

    /// Current terminal color scheme — resolved from ThemeManager (@AppStorage, instant).
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
    }

    // MARK: - macOS Three-Column Layout

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
                .toolbar {
                    // Capsule A: [📶│🔌│🔀│⏱]
                    ToolbarItem(placement: .automatic) {
                        ControlGroup {
                            Button { workspace.toggleBroadcast() } label: {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                            }
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

                    // Capsule B: [📁]
                    ToolbarItem(placement: .automatic) {
                        ControlGroup {
                            Button { toggleSFTPWindow() } label: {
                                Image(systemName: "folder.fill")
                            }
                        }
                    }

                    // Capsule C: [✨│📝]
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
            }
            .navigationSplitViewStyle(.balanced)
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
                    .environmentObject(i18n)
            }
            .sheet(isPresented: $workspace.isPortForwardingPresented) {
                PortForwardView(isPresented: $workspace.isPortForwardingPresented, sshService: sessionManager.activeTab?.sshService)
                    .environmentObject(i18n)
            }
            .sheet(isPresented: $workspace.isSessionManagerPresented) {
                SessionManagerView(isPresented: $workspace.isSessionManagerPresented, onConnect: { _ in })
                    .environmentObject(i18n)
            }
        }

        // MARK: - SFTP Window

        private func toggleSFTPWindow() {
            if let window = sftpWindow {
                window.close()
                sftpWindow = nil
            } else {
                openSFTPWindow()
            }
        }

        private func openSFTPWindow() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SFTP Browser"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SFTPWindowView(sessionManager: sessionManager)
                    .environmentObject(i18n)
                    .environment(workspace)
            )
            window.center()
            window.makeKeyAndOrderFront(nil)
            let delegate = SFTPWindowDelegate { self.sftpWindow = nil }
            window.delegate = delegate
            sftpWindow = window
        }
    #endif

    // MARK: - iOS Layout

    private var iOSLayout: some View {
        NavigationStack {
            HostListView(
                sessionManager: sessionManager,
                defaultPort: preferences.defaultPort
            )
            .navigationTitle("Bonk") // App name, not localized
            .navigationDestination(for: UUID.self) { tabID in
                if let tab = sessionManager.tabs.first(where: { $0.id == tabID }) {
                    iOSterminalDetail(tab)
                }
            }
        }
    }

    private func iOSterminalDetail(_ tab: TerminalTab) -> some View {
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
            onSend: { data in
                Task { try? await sessionManager.sendInput(data, to: tab.id) }
            },
            onResize: { cols, rows in
                Task { try? await sessionManager.resizePTY(cols: cols, rows: rows, tabID: tab.id) }
            },
            onTitleChange: { newTitle in
                sessionManager.updateTabTitle(newTitle, tabID: tab.id)
            },
            onReconnect: {
                Task { await sessionManager.reconnectTab(tab.id) }
            }
        )
        .navigationTitle(tab.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            Task { await sessionManager.reconnectTab(tab.id) }
                        } label: {
                            Label(i18n.t(.reconnect), systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive) {
                            Task { await sessionManager.closeTab(tab.id) }
                        } label: {
                            Label(i18n.t(.disconnect), systemImage: "bolt.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
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
