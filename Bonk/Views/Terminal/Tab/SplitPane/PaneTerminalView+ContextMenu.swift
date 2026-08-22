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
            NotificationCenter.default.post(name: .requestTerminalSelection, object: nil)
        } label: {
            Label(i18n.t(.copy), systemImage: "doc.on.doc")
        }

        Button {
            if let text = NSPasteboard.general.string(forType: .string) {
                sendInput(ArraySlice(text.utf8))
            }
        } label: {
            Label(i18n.t(.paste), systemImage: "doc.on.clipboard")
        }

        Button {
            if let cached = TerminalViewCache.shared.retrieve(paneState.id) {
                cached.view.selectAll()
            }
        } label: {
            Label(i18n.t(.selectAll), systemImage: "selection.pin.in.out")
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
                let title = tab.isBroadcastEnabled ? i18n.t(.disableBroadcast) : i18n.t(.enableBroadcast)
                let icon = tab.isBroadcastEnabled
                    ? "antenna.radiowaves.left.and.right.slash"
                    : "antenna.radiowaves.left.and.right"
                Label(title, systemImage: icon)
            }
        }

        Divider()

        // Zmodem file transfer
        Menu {
            Button {
                showFilePickerForZmodem()
            } label: {
                Label(i18n.t(.sendFile), systemImage: "arrow.up.circle")
            }
            Button {
                sessionManager.startZmodemReceive(tabID: tab.id, paneID: paneState.id)
            } label: {
                Label(i18n.t(.receiveFile), systemImage: "arrow.down.circle")
            }
        } label: {
            Label(i18n.t(.fileTransfer), systemImage: "arrow.up.arrow.down.circle")
        }

        Divider()

        // AI Assistant
        Button {
            NotificationCenter.default.post(name: .toggleAIChat, object: nil)
        } label: {
            Label(i18n.t(.aiAssistant), systemImage: "sparkles")
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
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(
                        width: dropPosition.isHorizontal ? size.width / 2 - inset * 2 : nil,
                        height: dropPosition.isVertical ? size.height / 2 - inset * 2 : nil
                    )
                    .position(center)

                // Icon
                VStack(spacing: 8) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: AppStyle.fontXL))
                    Text(i18n.t(.dropToSplit))
                        .font(.caption)
                }
                .foregroundStyle(Color.accentColor)
                .position(center)
            }
            .animation(.easeInOut(duration: 0.15), value: dropPosition)
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
        // Drop lands on THIS pane — pass its id so the new pane is inserted
        // next to the pane the user pointed at, not the active one.
        sessionManager.addPaneFromTab(
            sourceTabID,
            to: tab.id,
            paneID: paneState.id,
            position: position
        )
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

    // MARK: - Zmodem File Transfer

    func showFilePickerForZmodem() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK {
            let files = panel.urls
            sessionManager.startZmodemSend(tabID: tab.id, paneID: paneState.id, files: files)
        }
    }
}
