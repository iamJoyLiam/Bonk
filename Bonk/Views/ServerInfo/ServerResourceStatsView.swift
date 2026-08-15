//
//  ServerResourceStatsView.swift
//  Bonk
//
//  Circular resource indicators for the toolbar.
//
//  Each indicator is an NSButton subclass that draws its own ring. The button
//  is a first-class AppKit control, so tooltips, clicks, popover anchoring and
//  Command-dragging all work natively — no bitmap re-rendering, no mouse
//  coordinate fallback.
//

import AppKit
import SwiftUI

/// Which resource a toolbar ring represents.
enum ServerResourceKind {
    case cpu
    case memory
    case disk
}

// MARK: - Ring Control

/// Toolbar button that draws a circular percentage indicator.
@MainActor
final class ServerResourceRingControl: NSButton {
    let kind: ServerResourceKind
    private var percent: Double?

    init(
        kind: ServerResourceKind,
        label: String
    ) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 30))
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
        toolTip = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 32, height: 30)
    }

    func refresh(snapshot: ServerResourceSnapshot?) {
        percent = Self.percent(kind: kind, snapshot: snapshot)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The toolbar can stretch the control; always draw a true circle
        // centered on the shortest edge.
        let side = min(bounds.width, bounds.height)
        let square = NSRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
        let rect = square.insetBy(dx: 2.5, dy: 2.5)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let color = Self.color(percent: percent)

        // Track
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 3
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        track.stroke()

        // Progress arc, clockwise from 12 o'clock
        if let percent, percent > 0 {
            let progress = NSBezierPath()
            progress.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * min(max(percent / 100, 0), 1),
                clockwise: true
            )
            progress.lineWidth = 3
            progress.lineCapStyle = .round
            color.setStroke()
            progress.stroke()
        }

        // Percentage
        let text = percent.map { "\(Int($0.rounded()))%" } ?? "--"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.ringFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        string.draw(at: NSPoint(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2
        ))
    }

    /// Named font avoids macOS 26 display-list crashes seen with
    /// monospacedSystemFont's synthesized descriptor.
    private static let ringFont: NSFont =
        NSFont(name: "SFMono-Semibold", size: 11)
        ?? NSFont(name: "Menlo", size: 11)
        ?? NSFont.systemFont(ofSize: 11, weight: .semibold)

    private static func percent(kind: ServerResourceKind, snapshot: ServerResourceSnapshot?) -> Double? {
        switch kind {
        case .cpu: return snapshot?.info.cpuUsagePercent
        case .memory:
            guard let used = snapshot?.info.memUsedBytes,
                  let total = snapshot?.info.memTotalBytes,
                  total > 0 else { return nil }
            return Double(used) / Double(total) * 100
        case .disk:
            guard let used = snapshot?.info.diskUsedBytes,
                  let total = snapshot?.info.diskTotalBytes,
                  total > 0 else { return nil }
            return Double(used) / Double(total) * 100
        }
    }

    private static func color(percent: Double?) -> NSColor {
        guard let percent else { return .secondaryLabelColor }
        if percent >= 90 { return .systemRed }
        if percent >= 70 { return .systemOrange }
        return .systemGreen
    }
}

// MARK: - Toolbar Item Controller

/// Owns the toolbar item, feeds the ring control, opens the detail popover.
@MainActor
final class ServerResourceRingItemController {
    let item: NSToolbarItem

    private let kind: ServerResourceKind
    private let i18n: I18n
    private let onShowDetails: () -> Void
    private let control: ServerResourceRingControl
    private var popover: NSPopover?
    private var target: ServerResourceRingTarget?

    init(
        id: NSToolbarItem.Identifier,
        kind: ServerResourceKind,
        label: String,
        i18n: I18n,
        onShowDetails: @escaping () -> Void
    ) {
        self.kind = kind
        self.i18n = i18n
        self.onShowDetails = onShowDetails

        let control = ServerResourceRingControl(kind: kind, label: label)

        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.view = control

        self.item = item
        self.control = control

        let target = ServerResourceRingTarget { [weak self] in
            self?.togglePopover()
        }
        self.target = target
        control.target = target
        control.action = #selector(ServerResourceRingTarget.invoke)
        control.refresh(snapshot: ServerResourceMonitor.shared.snapshot)
        objc_setAssociatedObject(item, "serverResourceRingTarget", target, .OBJC_ASSOCIATION_RETAIN)

        observeResourceState()
    }

    private func observeResourceState() {
        withObservationTracking {
            _ = ServerResourceMonitor.shared.snapshot
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.observeResourceState()
                Task { @MainActor [weak self] in
                    self?.control.refresh(snapshot: ServerResourceMonitor.shared.snapshot)
                }
            }
        }
    }

    private func togglePopover() {
        if let popover, popover.isShown {
            popover.close()
            self.popover = nil
            return
        }

        let detail = ServerResourceDetailView(
            i18n: i18n,
            onRefresh: {
                Task { await ServerResourceMonitor.shared.refreshNow() }
            },
            onShowDetails: onShowDetails
        )
        let hosting = NSHostingView(rootView: detail)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 360)
        let viewController = NSViewController()
        viewController.view = hosting

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = viewController
        popover.contentSize = NSSize(width: 320, height: 360)
        popover.show(relativeTo: control.bounds, of: control, preferredEdge: .maxY)
        self.popover = popover
    }
}

/// Target-action bridge for the toolbar button.
@MainActor
private final class ServerResourceRingTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func invoke() {
        action()
    }
}

// MARK: - Detail Popover

struct ServerResourceDetailView: View {
    let i18n: I18n
    let onRefresh: () -> Void
    let onShowDetails: () -> Void

    @State private var monitor = ServerResourceMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = monitor.snapshot {
                header(snapshot.info)
                gauges(snapshot.info)
                Divider()
                systemRows(snapshot.info)
                Divider()
                HStack(spacing: 8) {
                    Button(action: onRefresh) {
                        Label(i18n.t(.refreshNow), systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    Button(action: onShowDetails) {
                        Label(i18n.t(.serverResourceDetail), systemImage: "sidebar.right")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.disconnected))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func header(_ info: ServerInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.tint)
            Text(info.hostname ?? "--")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if let ip = info.serverIP {
                Text(ip)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func gauges(_ info: ServerInfo) -> some View {
        HStack(spacing: 12) {
            gauge(
                title: i18n.t(.cpu),
                percent: percent(used: nil, total: nil, direct: info.cpuUsagePercent),
                detail: info.cpuUsagePercent.map { "\(Int($0.rounded()))%" }
            )
            gauge(
                title: i18n.t(.memory),
                percent: percent(used: info.memUsedBytes, total: info.memTotalBytes, direct: nil),
                detail: memoryDetail(info)
            )
            gauge(
                title: i18n.t(.disk),
                percent: percent(used: info.diskUsedBytes, total: info.diskTotalBytes, direct: nil),
                detail: diskDetail(info)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func gauge(title: String, percent: Double?, detail: String?) -> some View {
        VStack(spacing: 5) {
            Gauge(value: (percent ?? 0) / 100) {
                Text(title)
            } currentValueLabel: {
                Text(detail ?? "--")
                    .font(.caption.monospaced())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(gaugeColor(percent))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func systemRows(_ info: ServerInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let os = info.os {
                row(i18n.t(.os), os)
            }
            if let kernel = info.kernel {
                row(i18n.t(.kernel), kernel)
            }
            if let load = info.loadAverage {
                row(i18n.t(.loadAvg), load)
            }
            if let swapUsed = info.swapUsedBytes,
               let swapTotal = info.swapTotalBytes,
               swapTotal > 0
            {
                row(i18n.t(.swap), "\(formatBytes(swapUsed))/\(formatBytes(swapTotal))")
            }
            if let rx = info.networkRXRateBps, let tx = info.networkTXRateBps {
                row(i18n.t(.network), "↓ \(formatRate(rx))  ↑ \(formatRate(tx))")
            }
            if let read = info.diskReadRateBps, let write = info.diskWriteRateBps {
                row(i18n.t(.diskIO), "R \(formatRate(read))  W \(formatRate(write))")
            }
            if let temp = info.cpuTempCelsius {
                row(i18n.t(.cpuTemp), "\(Int(temp.rounded()))°C")
            }
            if let procs = info.topProcesses, !procs.isEmpty {
                row(i18n.t(.topProcesses), procs.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: ";", with: "  "))
            }
            if let ports = info.listenPorts, !ports.isEmpty {
                row(i18n.t(.listenPorts), ports.trimmingCharacters(in: CharacterSet(charactersIn: ",")))
            }
            if let seconds = info.uptimeSeconds {
                row(i18n.t(.uptime), formatUptime(seconds))
            }
        }
    }

    private func formatUptime(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private func percent(used: UInt64?, total: UInt64?, direct: Double?) -> Double? {
        if let direct { return direct }
        guard let used, let total, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }

    private func memoryDetail(_ info: ServerInfo) -> String? {
        guard let used = info.memUsedBytes, let total = info.memTotalBytes else { return nil }
        return formatBytes(used) + "/" + formatBytes(total)
    }

    private func diskDetail(_ info: ServerInfo) -> String? {
        guard let percent = percent(used: info.diskUsedBytes, total: info.diskTotalBytes, direct: nil) else {
            return nil
        }
        return "\(Int(percent.rounded()))%"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1fG", Double(bytes) / 1_073_741_824)
        }
        return "\(bytes / 1_048_576)M"
    }

    private func gaugeColor(_ percent: Double?) -> Color {
        guard let percent else { return .secondary }
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }
}
