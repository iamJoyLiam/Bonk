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
    @State private var showSFTP = false
  #endif

  private var preferences: UserPreferences {
    allPreferences.first ?? UserPreferences()
  }

  private func ensurePreferences() {
    if allPreferences.isEmpty {
      let new = UserPreferences()
      modelContext.insert(new)
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
          if showSFTP, let tab = sessionManager.activeTab {
            SFTPBrowserView(tab: tab)
          } else {
            ServerInfoPanel(
              tab: sessionManager.activeTab,
              onDisconnect: {
                if let id = sessionManager.activeTabID {
                  Task { await sessionManager.disconnectTab(id) }
                }
              },
              onReconnect: {
                if let id = sessionManager.activeTabID {
                  Task { await sessionManager.reconnectTab(id) }
                }
              }
            )
          }
        }
      }
      .navigationSplitViewStyle(.balanced)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          HStack(spacing: 6) {
            Button {
              if showInspector && !showSFTP {
                showInspector = false
              } else {
                showSFTP = false
                showInspector = true
              }
            } label: {
              Label(i18n.t(.serverInfo), systemImage: "server.rack")
            }
            .help(i18n.t(.serverInfo))

            Button {
              if showInspector && showSFTP {
                showInspector = false
              } else {
                showSFTP = true
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
      cursorStyle: preferences.cursorStyle,
      cursorBlink: preferences.cursorBlink,
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
