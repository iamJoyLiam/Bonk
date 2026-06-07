import SwiftData
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.modelContext) private var modelContext
    @Query private var allPreferences: [UserPreferences]
    @StateObject private var themeManager = TerminalThemeManager.shared

    @State private var sessionManager = SessionManager()
    #if os(macOS)
        @State private var showInspector = false
        @State private var inspectorMode: InspectorMode = .sftp

        enum InspectorMode { case sftp, aiChat }
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
        .onAppear {
            ensurePreferences()
            AIDataMigration.migrateIfNeeded(context: modelContext)
            AIDataMigration.migrateHostRelationships(context: modelContext)
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
                    switch inspectorMode {
                    case .sftp:
                        if let tab = sessionManager.activeTab {
                            SFTPBrowserView(tab: tab)
                        } else {
                            ContentUnavailableView(
                                i18n.t(.sftpBrowser),
                                systemImage: "folder.fill",
                                description: Text(i18n.t(.selectHost))
                            )
                        }
                    case .aiChat:
                        AIChatSidebarView()
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 6) {
                        Button {
                            if showInspector, inspectorMode == .aiChat {
                                showInspector = false
                            } else {
                                inspectorMode = .aiChat
                                showInspector = true
                            }
                        } label: {
                            Image(systemName: "sparkles")
                        }
                        .help(i18n.t(.aiAssistant))

                        Button {
                            if showInspector, inspectorMode == .sftp {
                                showInspector = false
                            } else {
                                inspectorMode = .sftp
                                showInspector = true
                            }
                        } label: {
                            Label(i18n.t(.sftp), systemImage: "folder.fill")
                        }
                        .help(i18n.t(.sftpBrowser))
                    }
                }
            }
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
