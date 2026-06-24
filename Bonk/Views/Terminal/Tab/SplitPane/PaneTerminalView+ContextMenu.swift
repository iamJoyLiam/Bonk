//
//  PaneTerminalView+ContextMenu.swift
//  Bonk
//
//  Context menu, drop indicator, and drag handlers for PaneTerminalView.
//

import SwiftTerm
import SwiftUI

extension PaneTerminalView {
    // MARK: - Context Menu

    @ViewBuilder
    var contextMenuContent: some View {
        // Copy/Paste
        Button {
            if let cached = TerminalViewCache.shared.retrieve(paneState.id),
               let selection = cached.view.getSelection(), !selection.isEmpty
            {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selection, forType: .string)
            }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button {
            if let text = NSPasteboard.general.string(forType: .string) {
                sendInput(ArraySlice(text.utf8))
            }
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }

        Button {
            if let cached = TerminalViewCache.shared.retrieve(paneState.id) {
                cached.view.selectAll()
            }
        } label: {
            Label("Select All", systemImage: "selection.pin.in.out")
        }

        Divider()

        // Split pane options
        Button { sessionManager.splitHorizontal() } label: {
            Label(i18n.t(.splitRight), systemImage: "rectangle.split.1x2")
        }
        Button { sessionManager.splitVertical() } label: {
            Label(i18n.t(.splitDown), systemImage: "rectangle.split.2x1")
        }

        // Broadcast option (only show when there are multiple panes)
        if tab.layout.root.paneCount > 1 {
            Button {
                sessionManager.toggleTabBroadcast(tab.id)
            } label: {
                let title = tab.isBroadcastEnabled ? "Disable Broadcast" : "Enable Broadcast"
                let icon = tab.isBroadcastEnabled
                    ? "antenna.radiowaves.left.and.right.slash"
                    : "antenna.radiowaves.left.and.right"
                Label(title, systemImage: icon)
            }
        }

        Divider()

        // AI Assistant
        Button {
            NotificationCenter.default.post(name: .toggleAIChat, object: nil)
        } label: {
            Label("AI Assistant", systemImage: "sparkles")
        }

        Divider()

        // Close pane
        Button(role: .destructive) {
            sessionManager.closePane(paneState.id, in: tab)
        } label: {
            Label(i18n.t(.closePane), systemImage: "xmark")
        }
        .disabled(tab.layout.root.paneCount <= 1)
    }

    // MARK: - Drop Indicator

    var dropIndicator: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let inset: CGFloat = 4
            let center = regionCenter(in: size)

            ZStack {
                // Region highlight
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .frame(
                        width: dropPosition.isHorizontal ? size.width / 2 - inset * 2 : nil,
                        height: dropPosition.isVertical ? size.height / 2 - inset * 2 : nil
                    )
                    .position(center)

                // Icon
                VStack(spacing: 8) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 24))
                    Text("Drop to split")
                        .font(.caption)
                }
                .foregroundStyle(Color.accentColor)
                .position(center)
            }
        }
    }

    func regionCenter(in size: CGSize) -> CGPoint {
        switch dropPosition {
        case .left: CGPoint(x: size.width / 4, y: size.height / 2)
        case .right: CGPoint(x: size.width * 3 / 4, y: size.height / 2)
        case .top: CGPoint(x: size.width / 2, y: size.height / 4)
        case .bottom: CGPoint(x: size.width / 2, y: size.height * 3 / 4)
        }
    }

    // MARK: - Drag Handlers

    func handleTabDrop(sourceTabID: UUID, position: DropPosition) {
        guard sourceTabID != tab.id else { return }
        sessionManager.addPaneFromTab(sourceTabID, to: tab.id, position: position)
    }

    func handleFileDrop(urls: [URL]) {
        guard tab.session?.connectionState.isConnected == true else { return }

        for url in urls {
            Task {
                // Clear cached CWD to force fresh path detection
                tab.currentDirectory = nil

                // Small delay to ensure terminal has processed any cd commands
                try? await Task.sleep(for: .milliseconds(100))

                // Use overwrite setting from preferences
                let overwriteAlways = preferences.sftpOverwriteAlways ?? false
                let uploaded = await uploadManager.handleDrop(
                    url: url,
                    tab: tab,
                    overwriteAlways: overwriteAlways,
                    i18n: i18n
                )
                if !uploaded {
                    // File exists, show overwrite dialog
                    pendingUploadURL = url
                    pendingUploadTab = tab
                    showOverwriteAlert = true
                }
            }
        }
    }

    func handleDragStateChange(isDragging: Bool, position: DropPosition) {
        isDragOver = isDragging
        dropPosition = position
    }

    // MARK: - Helpers

    func sendInput(_ data: ArraySlice<UInt8>) {
        Task {
            do {
                try await sessionManager.sendInput(data, to: tab.id, paneID: paneState.id)
            } catch {
                sessionManager.lastError = error.localizedDescription
                sessionManager.showError = true
            }
        }
    }

    func resizePTY(cols: Int, rows: Int) {
        Task {
            do {
                try await sessionManager.resizePTY(cols: cols, rows: rows, tabID: tab.id, paneID: paneState.id)
            } catch {}
        }
    }
}
