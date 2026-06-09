//
//  TerminalTabView.swift
//  Bonk
//
//  Created by Joy Liam on 2026/5/25.
//

import os.log
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Center area: tab bar + active terminal content.
struct TerminalTabView: View {
    @EnvironmentObject var i18n: I18n
    @Bindable var sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let cursorStyle: String
    let cursorBlink: Bool
    @Query private var allPreferences: [UserPreferences]
    @Query(sort: \HostItem.createdAt) var allHosts: [HostItem]
    @AppStorage("ai_enabled") var aiEnabled = false
    @State var showAIEnableAlert = false

    private var preferences: UserPreferences {
        allPreferences.first ?? UserPreferences()
    }

    @State var renamingTab: TerminalTab?
    @State var renameText = ""
    @State var dropMessage: String?
    @State var pendingUploadURL: URL?
    @State var pendingUploadTab: TerminalTab?
    @State var showOverwriteAlert = false
    @State var overwriteAlways = false
    @State var showAIChat = false
    @State var selectedTextForAI = ""
    @State var selectionObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if !sessionManager.tabs.isEmpty {
                    tabBar
                }

                if let activeTab = sessionManager.activeTab {
                    TerminalContainerView(
                        activeTab: activeTab,
                        colorScheme: colorScheme,
                        fontSize: preferences.fontSize,
                        fontFamily: preferences.fontFamily,
                        lineHeight: preferences.lineHeight,
                        scrollbackLines: preferences.scrollbackLines,
                        cursorStyle: cursorStyle,
                        cursorBlink: cursorBlink,
                        copyOnSelect: preferences.copyOnSelect,
                        onSend: { data in
                            Task {
                                do {
                                    try await sessionManager.sendInput(data, to: activeTab.id)
                                } catch {
                                    sessionManager.lastError = error.localizedDescription
                                    sessionManager.showError = true
                                }
                            }
                        },
                        onResize: { cols, rows in
                            Task {
                                do {
                                    try await sessionManager.resizePTY(cols: cols, rows: rows, tabID: activeTab.id)
                                } catch {
                                    // Resize failure is non-critical, log only
                                }
                            }
                        },
                        onTitleChange: { newTitle in
                            sessionManager.updateTabTitle(newTitle, tabID: activeTab.id)
                        },
                        onReconnect: {
                            Task { await sessionManager.reconnectTab(activeTab.id) }
                        }
                    )
                    .contextMenu {
                        Button {
                            requestSelectionAndShowAI()
                        } label: {
                            Label("AI Assistant", systemImage: "sparkles")
                        }

                        Divider()

                        Button {
                            copySelectedText()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .keyboardShortcut("c", modifiers: .command)

                        Button {
                            pasteToTerminal()
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .keyboardShortcut("v", modifiers: .command)

                        Button {
                            selectAllText()
                        } label: {
                            Label("Select All", systemImage: "selection.pin.in.out")
                        }
                        .keyboardShortcut("a", modifiers: .command)

                        Divider()

                        Button {
                            clearTerminal()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .keyboardShortcut("k", modifiers: .command)
                    }
                } else {
                    emptyState
                }
            }

            // AI Floating Bubble - truly floating, non-blocking
            if showAIChat {
                AIAssistantPanel(
                    initialText: selectedTextForAI,
                    onPaste: { text in
                        if let activeTab = sessionManager.activeTab {
                            let bytes = Array(text.utf8)
                            Task {
                                try? await sessionManager.sendInput(bytes[...], to: activeTab.id)
                            }
                        }
                        showAIChat = false
                        selectedTextForAI = ""
                    },
                    onDismiss: {
                        showAIChat = false
                        selectedTextForAI = ""
                        focusTerminal()
                    }
                )
                .zIndex(1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAIChat)) { _ in
            // Toggle AI chat
            if showAIChat {
                showAIChat = false
                selectedTextForAI = ""
                focusTerminal()
            } else {
                requestSelectionAndShowAI()
            }
        }
        .alert(i18n.t(.rename), isPresented: .init(
            get: { renamingTab != nil },
            set: { if !$0 { renamingTab = nil } }
        )) {
            TextField(i18n.t(.rename), text: $renameText)
            Button(i18n.t(.rename)) {
                if let tab = renamingTab, !renameText.isEmpty {
                    tab.title = renameText
                }
                renamingTab = nil
            }
            Button(i18n.t(.cancel), role: .cancel) {
                renamingTab = nil
            }
        } message: {
            Text(i18n.t(.enterNewName))
        }
        .alert("AI Assistant", isPresented: $showAIEnableAlert) {
            Button("Go to Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please enable AI in Settings → AI first.")
        }
        .onChange(of: renamingTab?.id) { _, _ in
            if let tab = renamingTab {
                renameText = tab.title
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = dropMessage {
                Text(msg)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let activeTab = sessionManager.activeTab,
                  activeTab.connectionState.isConnected else { return false }
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        await handleDrop(url: url, tab: activeTab)
                    }
                }
            }
            return true
        }
        .confirmationDialog(i18n.t(.fileExists), isPresented: $showOverwriteAlert) {
            Button(i18n.t(.overwrite)) {
                guard let url = pendingUploadURL, let tab = pendingUploadTab else { return }
                pendingUploadURL = nil
                pendingUploadTab = nil
                Task { await performUpload(url, tab: tab) }
            }
            Button(i18n.t(.alwaysOverwrite)) {
                guard let url = pendingUploadURL, let tab = pendingUploadTab else { return }
                overwriteAlways = true
                pendingUploadURL = nil
                pendingUploadTab = nil
                Task { await performUpload(url, tab: tab) }
            }
            Button(i18n.t(.cancel), role: .cancel) {
                pendingUploadURL = nil
                pendingUploadTab = nil
            }
        } message: {
            if let url = pendingUploadURL {
                Text(i18n.t(.fileExists).replacingOccurrences(of: "%@", with: url.lastPathComponent))
            }
        }
    }
}
