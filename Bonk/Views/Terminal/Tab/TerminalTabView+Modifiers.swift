//
//  TerminalTabView+Modifiers.swift
//  Bonk
//
//  ViewModifiers used by TerminalTabView.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Rename Alert

struct RenameAlertModifier: ViewModifier {
    let i18n: I18n
    @Binding var renamingTab: TerminalTab?
    @Binding var renameText: String

    func body(content: Content) -> some View {
        content
            .alert(i18n.t(.rename), isPresented: .init(
                get: { renamingTab != nil },
                set: { if !$0 { renamingTab = nil } }
            )) {
                TextField(i18n.t(.rename), text: $renameText)
                Button(i18n.t(.rename)) {
                    if let tab = renamingTab, !renameText.isEmpty { tab.title = renameText }
                    renamingTab = nil
                }
                Button(i18n.t(.cancel), role: .cancel) { renamingTab = nil }
            } message: { Text(i18n.t(.enterNewName)) }
    }
}

// MARK: - AI Enable Alert

struct AIEnableAlertModifier: ViewModifier {
    let i18n: I18n
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .alert(i18n.t(.aiAssistant), isPresented: $isPresented) {
                Button(i18n.t(.goToSettings)) {
                    UserDefaults.standard.set("ai", forKey: "settings_selected_tab")
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Button(i18n.t(.cancel), role: .cancel) {}
            } message: { Text(i18n.t(.enableAIHint)) }
    }
}

// MARK: - Drop Overlay

struct DropOverlayModifier: ViewModifier {
    @Binding var message: String?
    var uploadProgress: Double? = nil

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let msg = message {
                    VStack(spacing: 4) {
                        Text(msg)
                            .font(.caption)
                            .lineLimit(1)

                        if let progress = uploadProgress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 200)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }
}

// MARK: - File Drop Handler

struct FileDropHandlerModifier: ViewModifier {
    @Bindable var sessionManager: SessionManager
    @Binding var dropMessage: String?
    let onFileDrop: (URL, TerminalTab) -> Void

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let activeTab = sessionManager.activeTab,
                      activeTab.session?.connectionState.isConnected == true else { return false }
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                        guard let data = data as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        Task { @MainActor in
                            onFileDrop(url, activeTab)
                        }
                    }
                }
                return true
            }
    }
}

// MARK: - Overwrite Dialog

struct OverwriteDialogModifier: ViewModifier {
    let i18n: I18n
    @Binding var isPresented: Bool
    @Binding var pendingURL: URL?
    @Binding var pendingTab: TerminalTab?
    @Binding var overwriteAlways: Bool
    @Bindable var sessionManager: SessionManager
    let onUpload: (URL, TerminalTab) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingURL.map { i18n.tr(.fileExists, args: $0.lastPathComponent) } ?? i18n.t(.fileExists),
                isPresented: $isPresented
            ) {
                Button(i18n.t(.overwrite)) {
                    guard let url = pendingURL, let tab = pendingTab else { return }
                    pendingURL = nil; pendingTab = nil
                    onUpload(url, tab)
                }
                Button(i18n.t(.alwaysOverwrite)) {
                    guard let url = pendingURL, let tab = pendingTab else { return }
                    overwriteAlways = true; pendingURL = nil; pendingTab = nil
                    onUpload(url, tab)
                }
                Button(i18n.t(.cancel), role: .cancel) {
                    pendingURL = nil; pendingTab = nil
                }
            }
    }
}

// MARK: - View Extensions

extension View {
    func renameAlert(i18n: I18n, renamingTab: Binding<TerminalTab?>, renameText: Binding<String>) -> some View {
        modifier(RenameAlertModifier(i18n: i18n, renamingTab: renamingTab, renameText: renameText))
    }

    func aiEnableAlert(i18n: I18n, isPresented: Binding<Bool>) -> some View {
        modifier(AIEnableAlertModifier(i18n: i18n, isPresented: isPresented))
    }

    func dropOverlay(message: Binding<String?>, uploadProgress: Double? = nil) -> some View {
        modifier(DropOverlayModifier(message: message, uploadProgress: uploadProgress))
    }

    func fileDropHandler(sessionManager: SessionManager, dropMessage: Binding<String?>, onFileDrop: @escaping (URL, TerminalTab) -> Void) -> some View {
        modifier(FileDropHandlerModifier(sessionManager: sessionManager, dropMessage: dropMessage, onFileDrop: onFileDrop))
    }

    func overwriteDialog(
        i18n: I18n,
        isPresented: Binding<Bool>,
        pendingURL: Binding<URL?>,
        pendingTab: Binding<TerminalTab?>,
        overwriteAlways: Binding<Bool>,
        sessionManager: SessionManager,
        onUpload: @escaping (URL, TerminalTab) -> Void
    ) -> some View {
        modifier(OverwriteDialogModifier(
            i18n: i18n, isPresented: isPresented,
            pendingURL: pendingURL, pendingTab: pendingTab,
            overwriteAlways: overwriteAlways, sessionManager: sessionManager,
            onUpload: onUpload
        ))
    }
}
