import AppKit
import SwiftTerm
import SwiftUI

struct RecordingPlaybackView: View {
    @Environment(I18n.self) var i18n
    let url: URL
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var speed: Double = 1.0
    @State private var task: Task<Void, Never>?
    @State private var terminalView: SwiftTerm.TerminalView?
    @State private var headerTitle: String = ""
    @State private var hasStarted = false
    @State private var isHoveringControls = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ──
            HStack(spacing: AppStyle.spacingL) {
                // Left: icon + title
                HStack(spacing: AppStyle.spacingML) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall, style: .continuous)
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: AppStyle.buttonLarge, height: AppStyle.buttonLarge)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: AppStyle.fontLarge))
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackDisplayName)
                            .font(.system(size: AppStyle.fontRegular, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !headerTitle.isEmpty {
                            Text(headerTitle)
                                .font(.system(size: AppStyle.fontCaption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(fileSubtitle)
                                .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Speed pill
                HStack(spacing: AppStyle.spacingXS) {
                    Button { speed = max(0.25, speed - 0.25) } label: {
                        Image(systemName: "minus")
                            .font(.system(size: AppStyle.fontCaption, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .disabled(speed <= 0.25)

                    Text("×\(String(format: "%.2g", speed))")
                        .font(.system(size: AppStyle.fontSmall, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 38)
                        .monospacedDigit()

                    Button { speed = min(5, speed + 0.25) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: AppStyle.fontCaption, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .disabled(speed >= 5)
                }
                .padding(.horizontal, AppStyle.spacingS)
                .padding(.vertical, AppStyle.spacingXS)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
                )

                // Play / Pause — prominent capsule
                Button {
                    if isPlaying { task?.cancel(); isPlaying = false } else { play() }
                } label: {
                    HStack(spacing: AppStyle.spacingXS) {
                        Image(systemName: isPlaying ? "pause.fill" : (hasStarted ? "arrow.counterclockwise" : "play.fill"))
                            .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                        Text(isPlaying ? i18n.t(.pause) : (hasStarted ? i18n.t(.replay) : i18n.t(.play)))
                            .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppStyle.spacingXL)
                    .padding(.vertical, AppStyle.spacingSPlus)
                    .background(Capsule().fill(isPlaying ? Color.orange : Color.accentColor))
                    .shadow(color: (isPlaying ? Color.orange : Color.accentColor).opacity(0.25), radius: 6, y: 2)
                }
                .buttonStyle(.plain)

                Button { task?.cancel(); NSApp.keyWindow?.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppStyle.fontSmall, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.close))
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingML)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Progress — thin, accent
            PanelProgressBar(progress: progress)
                .padding(.horizontal, AppStyle.spacingXL)
                .padding(.vertical, AppStyle.spacingS)

            // Terminal canvas
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: Color.black.opacity(0.06), radius: 12, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                            .strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1)
                    )
                PlaybackTerminalBridge(terminalView: $terminalView)
                    .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous))
                    .padding(1)
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.bottom, AppStyle.spacingXL)
            .frame(minHeight: 360)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { task?.cancel() }
        .onAppear {
            parseHeader()
            if !hasStarted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { play() }
            }
        }
        .onChange(of: terminalView != nil) { _, ready in
            if ready, !hasStarted, !isPlaying { play() }
        }
    }

    private var fileSubtitle: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        return fmt.string(fromByteCount: Int64(size))
    }

    private var playbackDisplayName: String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        guard parts.count >= 4 else { return name }
        let host = String(parts[0])
        let timestamp = parts.suffix(1).first.map(String.init) ?? ""
        let date = timestamp.replacingOccurrences(of: "-", with: ":").prefix(16)
        return "\(host) · \(date)"
    }

    private func parseHeader() {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let firstLine = content.split(separator: "\n", omittingEmptySubsequences: false).first
        guard let line = firstLine, let data = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let title = obj["title"] as? String { headerTitle = title }
    }

    // swiftlint:disable:next function_body_length
    private func play() {
        guard let targetTerminal = terminalView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { play() }
            return
        }
        task?.cancel()
        hasStarted = true
        isPlaying = true
        progress = 0
        targetTerminal.terminal.resetToInitialState()
        targetTerminal.clearScrollback()

        task = Task {
            struct PlaybackEvent { let time: Double; let data: String }
            let captureURL = url
            let parsed: (events: [PlaybackEvent], total: Double)? = await Task
                .detached(priority: .userInitiated) { () -> (events: [PlaybackEvent], total: Double)? in
                    guard let content = try? String(contentsOf: captureURL, encoding: .utf8) else { return nil }
                    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                    guard lines.count > 1 else { return nil }
                    var events: [PlaybackEvent] = []
                    events.reserveCapacity(lines.count - 1)
                    for line in lines.dropFirst() {
                        if line.isEmpty { continue }
                        guard let data = line.data(using: .utf8),
                              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                              array.count == 3,
                              let timestamp = array[0] as? Double,
                              let kind = array[1] as? String, kind == "o",
                              let payload = array[2] as? String
                        else { continue }
                        events.append(PlaybackEvent(time: timestamp, data: payload))
                    }
                    let total = events.last?.time ?? 1
                    return (events, total)
                }.value
            guard let parsed else {
                await MainActor.run { isPlaying = false }
                return
            }
            let events = parsed.events
            let total = parsed.total
            var lastTime: Double = 0
            for event in events {
                if Task.isCancelled { break }
                let currentSpeed = await MainActor.run { speed }
                let denom = max(currentSpeed, 0.05)
                let delta = (event.time - lastTime) / denom
                let sleep = min(delta, 1.0 / denom)
                if sleep > 0.01 { try? await Task.sleep(for: .seconds(sleep)) }
                if Task.isCancelled { break }
                await MainActor.run {
                    targetTerminal.feed(text: event.data)
                    progress = total > 0 ? min(1, event.time / total) : 1
                }
                lastTime = event.time
            }
            await MainActor.run {
                isPlaying = false
                progress = 1
            }
        }
    }
}

// MARK: - Terminal bridge (isolated scrollback, read-only)

private struct PlaybackTerminalBridge: NSViewRepresentable {
    @Binding var terminalView: SwiftTerm.TerminalView?

    func makeNSView(context: Context) -> NSScrollView {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let terminal = SwiftTerm.TerminalView(
            frame: NSRect(x: 0, y: 0, width: 740, height: 420),
            font: font
        )
        let scroll = NSScrollView()
        scroll.documentView = terminal
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        DispatchQueue.main.async { terminalView = terminal }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject {}
}
