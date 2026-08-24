import SwiftUI

struct RecordingListView: View {
    @Environment(I18n.self) var i18n
    @State private var urls: [URL] = []
    @State private var hoveredURL: URL?
    @State private var pendingDelete: URL?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                icon: "recordingtape",
                title: i18n.t(.recordings),
                count: urls.count,
                countLabel: i18n.tr(.workspaceCount, args: urls.count)
            )
            Divider()
            if urls.isEmpty {
                PanelEmptyView(
                    icon: "recordingtape",
                    title: i18n.t(.noRecordings),
                    hint: i18n.t(.noRecordingsHint)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: AppStyle.spacingS) {
                        ForEach(urls, id: \.self) { url in
                            recordingCard(url)
                        }
                    }
                    .padding(AppStyle.spacingL)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { reload() }
        .alert(i18n.t(.delete), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(i18n.t(.cancel), role: .cancel) { pendingDelete = nil }
            Button(i18n.t(.delete), role: .destructive) {
                if let url = pendingDelete { delete(url) }
                pendingDelete = nil
            }
        } message: {
            if let url = pendingDelete {
                Text(playbackDisplayName(for: url))
            }
        }
    }

    // MARK: - Card

    private func recordingCard(_ url: URL) -> some View {
        let isHovered = hoveredURL == url
        return HStack(spacing: AppStyle.spacingL) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: AppStyle.fontLarge))
                .foregroundStyle(.blue)
                .frame(width: AppStyle.buttonLarge, height: AppStyle.buttonLarge)

            VStack(alignment: .leading, spacing: 3) {
                Text(playbackDisplayName(for: url))
                    .font(.system(size: AppStyle.fontRegular, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(fileInfo(url))
                    .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AppStyle.spacingM)

            HStack(spacing: AppStyle.spacingS) {
                Button { openPlayback(url) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                        .background(Circle().fill(Color.accentColor))
                        .shadow(color: Color.accentColor.opacity(0.25), radius: isHovered ? 6 : 0, y: 2)
                }
                .buttonStyle(.plain)
                .help(i18n.t(.play))

                Button { share(url) } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: AppStyle.fontSmall))
                        .foregroundStyle(.secondary)
                        .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.share))

                Button { pendingDelete = url } label: {
                    Image(systemName: "trash")
                        .font(.system(size: AppStyle.fontSmall))
                        .foregroundStyle(.red.opacity(0.9))
                        .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                        .background(Circle().fill(Color.red.opacity(0.08)))
                        .overlay(Circle().strokeBorder(Color.red.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.delete))
            }
            .opacity(isHovered ? 1 : 0.92)
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingML)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: Color.black.opacity(isHovered ? 0.06 : 0.03), radius: isHovered ? 8 : 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.08 : 0.04), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredURL = hovering ? url : nil
            }
        }
        .onTapGesture(count: 2) { openPlayback(url) }
        .contextMenu {
            Button { openPlayback(url) } label: { Label(i18n.t(.play), systemImage: "play.circle") }
            Button { share(url) } label: { Label(i18n.t(.share), systemImage: "square.and.arrow.up") }
            Divider()
            Button(role: .destructive) { pendingDelete = url } label: { Label(i18n.t(.delete), systemImage: "trash") }
        }
    }

    // MARK: - Helpers

    private func fileInfo(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let date = (attrs?[.creationDate] as? Date) ?? Date()
        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        return "\(fmt.string(fromByteCount: Int64(size))) · \(df.string(from: date))"
    }

    private func reload() {
        Task { urls = await SessionRecordingService.shared.listRecordings() }
    }

    private func delete(_ url: URL) {
        Task { try? await SessionRecordingService.shared.delete(url: url); reload() }
    }

    private func share(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func playbackDisplayName(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        guard parts.count >= 4 else { return name }
        let host = String(parts[0])
        let ts = parts.suffix(1).first.map(String.init) ?? ""
        let date = ts.replacingOccurrences(of: "-", with: ":").prefix(16)
        return "\(host) · \(date)"
    }

    private func openPlayback(_ url: URL) {
        let view = RecordingPlaybackView(url: url).environment(i18n)
        let hostingView = NSHostingView(rootView: view)
        hostingView.autoresizingMask = [.width, .height]
        let contentSize = NSSize(width: 760, height: 520)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.title = "\(playbackDisplayName(for: url))"
        window.subtitle = fileInfo(url)
        window.representedURL = url
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setContentSize(contentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
