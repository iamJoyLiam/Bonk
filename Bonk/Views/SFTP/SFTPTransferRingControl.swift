//
//  SFTPTransferRingControl.swift
//  Bonk
//
//  Toolbar ring + popover for in-flight SFTP transfers.
//
//  ## Deliberately the same shape as the CPU/memory/disk ring
//
//  This has been rewritten several times, and every rewrite used a different
//  mechanism — `NSBezierPath` arcs in `draw(_:)`, then a nested
//  `NSProgressIndicator` inside a borderless button. Both looked wrong and
//  neither responded to clicks. `ServerResourceRingControl` is a known-good ring
//  sitting in this same toolbar, so this copies it: an `NSButton` subclass that
//  draws its own circle, used **directly** as `NSToolbarItem.view`, with the
//  percentage drawn inside. Drawing the number is what makes it legible as a
//  percentage rather than as a decoration.
//
//  ## Two directions
//
//  Uploads and downloads run independently. The ring shows the direction that is
//  currently active — download first, since a stalled download is the case worth
//  noticing — and the glyph beside the percentage says which. When the total is
//  unknowable the ring shows `--` rather than a fabricated number.
//

import AppKit
import SwiftUI

/// Toolbar ring showing SFTP transfer progress.
@MainActor
final class SFTPTransferRingControl: NSButton {
    private(set) var aggregate: SFTPTransferAggregate = .none

    /// Shared with the server rings via `AppStyle.toolbarRingSize`, so the two
    /// cannot drift apart again — which is what made the earlier mismatch read as
    /// one broken item rather than as two designs.
    static let size = AppStyle.toolbarRingSize

    init(label: String) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
        toolTip = label
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { Self.size }

    /// The toolbar hit-tests the drawn pixels of a custom view. A cleared
    /// context makes the ring transparent, so the click falls through and the
    /// arc never composites. Declaring the view non-opaque lets AppKit clear
    /// the previous frame without punching that hole.
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    func refresh(aggregate: SFTPTransferAggregate) {
        self.aggregate = aggregate
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The direction the ring reports on.
    ///
    /// Download wins when both are active: a transfer that has stalled is the
    /// thing a user is watching this ring for, and uploads usually accompany a
    /// download rather than replace it.
    private var activeDirection: SFTPDirectionAggregate {
        aggregate.download.isActive ? aggregate.download : aggregate.upload
    }

    private var isUploading: Bool {
        aggregate.download.isActive ? false : aggregate.upload.isActive
    }

    /// Ring colour carries the direction.
    ///
    /// Upload is `systemBlue` at the user's request, so download takes
    /// `systemIndigo`: close enough to read as the same family, distinct enough to
    /// tell apart at a glance. Orange was tried first and read as "warning".
    private var directionColor: NSColor {
        guard aggregate.isActive else { return .controlAccentColor }
        return isUploading ? .systemBlue : .systemIndigo
    }

    override func draw(_ dirtyRect: NSRect) {
        // Sidebar vibrancy can leave a toolbar item's effective appearance stuck in
        // aqua while the app is darkAqua, so system colours only resolve correctly
        // inside this. Copied from the server rings for the same reason.
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let side = min(bounds.width, bounds.height)
            let square = NSRect(
                x: (bounds.width - side) / 2,
                y: (bounds.height - side) / 2,
                width: side, height: side
            )
            // Shared with the server rings so the two cannot drift; see
            // `AppStyle.ringStrokeInset` for why it is exactly half the stroke.
            let rect = square.insetBy(
                dx: AppStyle.ringStrokeInset, dy: AppStyle.ringStrokeInset)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2
            let running = activeDirection

            // Finished-but-not-yet-removed. Drawn before anything else so a
            // completed transfer reads as "done" rather than as a stalled bar —
            // the exact ambiguity that made a finished upload indistinguishable
            // from one that had hung.
            if !aggregate.isActive, aggregate.hasJustCompleted {
                drawCompletedGlyph(in: rect)
                return
            }

            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = AppStyle.ringLineWidth
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            track.stroke()

            if let fraction = running.fraction, fraction > 0 {
                let progress = NSBezierPath()
                progress.appendArc(
                    withCenter: center, radius: radius,
                    startAngle: 90,
                    endAngle: 90 - 360 * min(max(fraction, 0), 1),
                    clockwise: true
                )
                progress.lineWidth = AppStyle.ringLineWidth
                progress.lineCapStyle = .round
                directionColor.setStroke()
                progress.stroke()
            }

            drawCenterText(running: running)
        }
    }

    /// Finished state. The same symbol the transfer list draws:
    /// `checkmark.circle.fill` in green, with the check knocked out in white.
    ///
    /// Drawn at the symbol's own point size. Putting that bitmap into a
    /// different rectangle resamples it, which is why the toolbar copy looked
    /// soft next to the sharp one in the SFTP window.
    private func drawCompletedGlyph(in rect: NSRect) {
        let pointSize = min(rect.width, rect.height)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
        guard let image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let symbolSize = image.size
        let box = NSRect(
            x: rect.midX - symbolSize.width / 2,
            y: rect.midY - symbolSize.height / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )
        image.draw(
            in: box,
            from: NSRect(origin: .zero, size: symbolSize),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    /// Direction arrow and percentage inside the ring.
    ///
    /// Laid out as one centred unit so the pair cannot drift off the circle, and
    /// shrunk a step when the text is wide (`100%`) so the widest case still fits
    /// the inner width. The arrow is hidden at 100% — the row is finished and a
    /// full ring already says so.
    private func drawCenterText(running: SFTPDirectionAggregate) {
        let layout = Self.centerTextLayout(
            running: running, isUploading: isUploading, arrowColor: directionColor,
            availableWidth: Self.innerTextWidth(for: bounds))

        guard let arrow = layout.arrow else {
            draw(layout.number, centeredIn: bounds)
            return
        }

        let numberSize = layout.number.size()
        let arrowSize = arrow.size()
        var origin = NSPoint(
            x: (bounds.midX - layout.totalWidth / 2),
            y: bounds.midY - max(numberSize.height, arrowSize.height) / 2
        )
        arrow.draw(at: origin)
        origin.x += arrowSize.width + Self.centerTextGap
        layout.number.draw(at: origin)
    }

    static let centerTextGap: CGFloat = 1

    /// The centre text and the width it actually occupies.
    ///
    /// ## Why this measures instead of trusting a font size
    ///
    /// The text used to be sized by stepping down a hardcoded point size, which
    /// only fits by coincidence: it overflowed the ring by 0.13pt at the current
    /// size, and the same sizes would overflow differently under a different
    /// system font, locale, or Dynamic Type setting. A size that happens to fit
    /// today is not a property of the code.
    ///
    /// So the width is measured and the font scaled until it fits. Glyph advances
    /// scale close to linearly with point size, so one proportional correction is
    /// nearly exact; the loop runs a bounded number of times to cover the rest and
    /// keeps the result honest rather than truncating the string.
    ///
    /// Shared with the sizing gate, so the test measures the same layout the ring
    /// draws. A gate that re-implements the layout measures its own assumptions,
    /// not the ring — the same wrong-layer mistake that let the completion tick
    /// ship as unreachable code.
    static func centerTextLayout(
        running: SFTPDirectionAggregate,
        isUploading: Bool,
        arrowColor: NSColor,
        availableWidth: CGFloat
    ) -> (number: NSAttributedString, arrow: NSAttributedString?, totalWidth: CGFloat, fontSize: CGFloat) {
        let text: String
        if !running.isActive {
            text = "sftp"
        } else if let fraction = running.fraction {
            text = "\(Int((fraction * 100).rounded()))%"
        } else {
            text = "--"
        }
        // The arrow is hidden at 100% — the row is finished and a full ring already
        // says so, and dropping it frees the width the widest percentage needs.
        let showArrow = running.isActive && (running.fraction ?? 0) < 0.995
        let nominal: CGFloat = text.count >= 4
            ? AppStyle.ringTextFontSizeNarrow - 0.5
            : AppStyle.ringTextFontSize - 1

        func build(_ size: CGFloat) -> (NSAttributedString, NSAttributedString?, CGFloat) {
            let number = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            guard showArrow else { return (number, nil, number.size().width) }
            let arrow = NSAttributedString(
                string: isUploading ? "↑" : "↓",
                attributes: [
                    .font: NSFont.systemFont(ofSize: size - 0.5, weight: .bold),
                    .foregroundColor: arrowColor,
                ]
            )
            return (number, arrow, arrow.size().width + centerTextGap + number.size().width)
        }

        // Fit to slightly less than the full inner width. Two reasons, and the
        // second is not cosmetic: text scaled to exactly the available width lands
        // a fraction over it after rounding — it measured 29.00000002 against 29 —
        // so an exact fit is not a fit. The margin also keeps the text visibly
        // inside the circle instead of touching it, which is the "it overflows"
        // complaint in the first place.
        let target = availableWidth * Self.centerTextFitRatio
        var size = nominal
        var layout = build(size)
        var attempts = 0
        while layout.2 > target, size > Self.minimumCenterTextSize, attempts < 4 {
            // Advance scales roughly with point size, so step proportionally rather
            // than guessing a fixed decrement.
            size = max(Self.minimumCenterTextSize, size * (target / layout.2))
            layout = build(size)
            attempts += 1
        }
        return (layout.0, layout.1, layout.2, size)
    }

    /// Floor for the fitted size. Below this the percentage is no longer legible,
    /// and a ring that cannot show the number legibly is worse than one that shows
    /// it slightly wide — so the floor is where fitting stops, not where it clips.
    static let minimumCenterTextSize: CGFloat = 7

    /// Fraction of the inner width the centre text is fitted to.
    ///
    /// The remainder is deliberate clearance, not slack.
    static let centerTextFitRatio: CGFloat = 0.94

    /// The width available to text inside the ring.
    ///
    /// The circle is drawn on the shortest edge and inset by the stroke allowance,
    /// so this is the diameter the centre text has to fit within.
    static func innerTextWidth(for bounds: NSRect) -> CGFloat {
        let side = min(bounds.width, bounds.height)
        return side - 2 * AppStyle.ringStrokeInset
    }

    private func draw(_ string: NSAttributedString, centeredIn rect: NSRect) {
        let size = string.size()
        string.draw(at: NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        ))
    }

    /// Named fonts: macOS 26 display-list crashes were seen with
    /// `monospacedSystemFont`'s synthesized descriptor.
    private static let ringFont = NSFont.systemFont(ofSize: 8.5, weight: .medium)
}

/// Owns the toolbar item, tracks transfers, and opens the popover.
@MainActor
final class SFTPTransferRingItemController: NSObject {
    let item: NSToolbarItem
    static let identifier = NSToolbarItem.Identifier("sftpTransfers")

    private let control: SFTPTransferRingControl
    private let i18n: I18n
    private let sessionManager: SessionManager
    private let workspace: WorkspaceManager
    private var popover: NSPopover?
    /// Cancelled in `deinit`; holding it would keep this controller alive for the
    /// life of the app because the stream's continuation outlives the item.
    private var observationTasks: [Task<Void, Never>] = []
    private var watcherTask: Task<Void, Never>?
    private var observedServiceCount: Int = 0
    private let updater = SFTPRingUpdater()
    private let target: SFTPTransferRingTarget

    override init() { fatalError("use init(coordinator:)") }

    init(coordinator: ToolbarCoordinator) {
        self.i18n = coordinator.i18n
        self.sessionManager = coordinator.sessionManager
        self.workspace = coordinator.workspace

        let label = coordinator.i18n.t(.sftpBrowser)
        let control = SFTPTransferRingControl(label: label)
        self.control = control

        let item = NSToolbarItem(itemIdentifier: Self.identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        // The control **is** the item's view. An earlier version nested it inside
        // a borderless, imageless NSButton, which has almost no hit area — the
        // ring was visible but clicks never landed on it.
        item.view = control
        // Pin the footprint. A custom-view toolbar item reserves its intrinsic size
        // and the toolbar adds item spacing around it, so an unpinned ring sat in a
        // visibly wider slot than the `item.image` icons next to it. Pinning makes
        // the slot exactly the ring.
        item.minSize = SFTPTransferRingControl.size
        item.maxSize = SFTPTransferRingControl.size
        self.item = item

        self.target = SFTPTransferRingTarget()

        // All stored properties are initialised, so `super.init()` can run. The
        // target's closure captures `self`, and Swift forbids forming it before
        // `super.init()`, so the wiring happens in `wireUp()`.
        super.init()
        wireUp()
        observeTransfers()
    }

    deinit {
        for task in observationTasks { task.cancel() }
        watcherTask?.cancel()
    }

    /// Connect control → target → controller.
    ///
    /// Split out of `init` because a closure capturing `self` cannot be formed
    /// before `super.init()` has run.
    private func wireUp() {
        target.action = { [weak self] in self?.togglePopover() }
        control.target = target
        control.action = #selector(SFTPTransferRingTarget.invoke)
    }

    // MARK: - Tracking

    /// Consume the service's tick stream on the main actor.
    ///
    /// ## Why this replaced `withObservationTracking`
    ///
    /// The previous implementation registered an observation whose callback closure
    /// is nonisolated, while the observed state is `@MainActor`. That combination
    /// is the reason the toolbar item "froze" the instant a transfer started: the
    /// observation was registered from a context that does not own the state, so it
    /// fired unreliably and — when it re-armed from inside its own callback — could
    /// amplify rather than settle.
    ///
    /// A stream yields into the actor, so the continuation resumes on the main
    /// actor with the state already valid. There is nothing to re-arm, nothing to
    /// unregister on close, and the update count is bounded by the number of ticks.
    private func observeTransfers() {
        let services = transferServices()
        observedServiceCount = services.count
        for task in observationTasks { task.cancel() }
        // The loop lives in `SFTPRingUpdater` so the coalescing is exercised by
        // tests rather than only in the app.
        observationTasks = updater.makeConsumerTasks(services: services) {
            [weak self] in self?.applyCurrentState()
        }
        applyCurrentState()
        startServiceWatcher()
    }

    /// Re-arm when the set of sessions changes.
    ///
    /// A session opened after this controller was built has no stream consumer yet,
    /// and the previous `withObservationTracking` approach would have noticed that
    /// for free. So this watches for it — on a fixed cadence, deliberately: the
    /// failure mode being avoided here is a callback whose re-registration
    /// amplifies, and a timer cannot amplify.
    private func startServiceWatcher() {
        watcherTask?.cancel()
        watcherTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if self.observedServiceCount != self.transferServices().count {
                    self.observeTransfers()
                }
            }
        }
    }

    /// Recompute and redraw from the live services.
    private func applyCurrentState() {
        let aggregate = currentAggregate()
        control.refresh(aggregate: aggregate)
        let text = describe(aggregate)
        item.toolTip = text
        control.toolTip = text
    }

    private func currentAggregate() -> SFTPTransferAggregate {
        SFTPRingState.aggregate(services: transferServices())
    }

    /// Tooltip composed from the real `upload` / `download` nouns and a plain
    /// count — never a count-substituted banner phrase.
    private func describe(_ aggregate: SFTPTransferAggregate) -> String {
        guard aggregate.isActive else { return i18n.t(.sftpBrowser) }
        var parts: [String] = []
        if aggregate.download.count > 0 {
            parts.append("\(i18n.t(.download)) ×\(aggregate.download.count)")
        }
        if aggregate.upload.count > 0 {
            parts.append("\(i18n.t(.upload)) ×\(aggregate.upload.count)")
        }
        return parts.joined(separator: " / ")
    }

    // MARK: - Popover

    private func togglePopover() {
        if let popover, popover.isShown {
            popover.close()
            self.popover = nil
            return
        }
        presentPopover()
    }

    private func presentPopover() {
        let detail = SFTPTransferListView(
            i18n: i18n,
            services: transferServices(),
            onOpenSFTP: { [weak self] in
                self?.popover?.close()
                self?.workspace.toggleSFTPWindow()
            }
        )
        let size = NSSize(width: 340, height: 320)
        let viewController = NSHostingController(rootView: AnyView(detail))
        viewController.view.frame = NSRect(origin: .zero, size: size)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = viewController
        popover.contentSize = size
        popover.delegate = self
        popover.show(relativeTo: control.bounds, of: control, preferredEdge: .maxY)
        self.popover = popover
    }

    /// Every SFTP service currently backing a session.
    ///
    /// Passed to the popover as live observable objects rather than a snapshot of
    /// transfers. An earlier version swapped `NSHostingController.rootView` from
    /// inside the observation handler to keep the list ticking; that is
    /// re-entrant — the handler fires while SwiftUI is updating, which is exactly
    /// when the SFTP window opens or closes and `isSFTPWindowOpen` flips. It wedged
    /// the main thread and the toolbar item stopped responding for good.
    private func transferServices() -> [SFTPService] {
        sessionManager.tabs.compactMap { $0.session?.sftpService }
    }

}

extension SFTPTransferRingItemController: NSPopoverDelegate {
    /// Release the closed popover so a later click starts from a clean slate.
    ///
    /// Without this the controller keeps a strong reference to a popover the user
    /// already dismissed, and each open/close cycle piles another one up.
    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}

/// Assembles the aggregate the ring draws.
enum SFTPRingState {
    /// Every transfer from every service, **including finished ones**.
    ///
    /// Filtering finished transfers here was the defect behind "the upload finished
    /// and the ring never said so": `SFTPTransferAggregate` separates running from
    /// finished on its own, but it cannot do that from a list that has already had
    /// the finished entries removed. Every transfer arrived pre-filtered, so
    /// `completedCount` was permanently zero and the completion state could never be
    /// drawn. The split belongs in the aggregate, not here.
    @MainActor
    static func transfers(services: [SFTPService]) -> [SFTPTransfer] {
        services.flatMap { $0.transfers }
    }

    @MainActor
    static func aggregate(services: [SFTPService]) -> SFTPTransferAggregate {
        SFTPTransferAggregate(transfers: transfers(services: services))
    }
}

/// Consumes transfer ticks and coalesces them into redraws.
///
/// ## Why coalescing is the fix, not an optimisation
///
/// `SFTPService` yields one tick per `transfers` mutation. The OpenSSH transfer
/// path mutates on every tenth chunk, which at local-file speeds is thousands of
/// ticks per second. Each tick used to run a full `applyCurrentState()` on the
/// main actor — rebuild every session's transfers, fold them into an aggregate,
/// rewrite two tooltips, mark the ring dirty. Thousands of those per second is
/// enough to saturate the main actor, and a saturated main actor is exactly what
/// "the icon went dead the moment I started an upload" looks like: no repaint, no
/// click, no spinner anywhere in the app.
///
/// ## Why draining and painting are separate tasks
///
/// The obvious coalescing — sleep inside the `for await` — is worse than the
/// original bug. `for await` consumes exactly one buffered element per iteration,
/// so throttling the loop to 10 repaints/second also throttles *draining* to 10
/// elements/second. A burst of 3000 ticks would then take 300 seconds to clear and
/// the ring would show progress long after the transfer had finished.
///
/// So: one task per service does nothing but count ticks — the cheapest possible
/// work per element — and a single painter repaints at a fixed cadence if anything
/// arrived since the last frame. Draining is never delayed; only painting is.
/// Nothing is dropped, and the final state is always painted.
@MainActor
final class SFTPRingUpdater {
    /// Repaint interval. Fast enough to look live, cheap enough to be invisible.
    static let interval = Duration.milliseconds(100)

    /// Ticks seen since the last repaint.
    private var pending = 0

    /// Ticks consumed since start.
    ///
    /// Exposed because *drain lag* is a failure mode in its own right, distinct
    /// from paint rate, and invisible to a test that only counts repaints: the
    /// painter reads live state, so a stalled drain looks like a perfectly current
    /// ring. The ring's wake-up signal is the drain, so a drain that falls behind
    /// means a completed transfer can wait minutes to be noticed.
    private(set) var drainedCount = 0

    /// How many times `apply` has actually run. Test-facing; production only reads
    /// it to prove the coalescing is doing something.
    private(set) var applyCount = 0

    /// The production consumption loop, verbatim.
    ///
    /// Returns the tasks rather than awaiting them so the caller owns their
    /// lifetime — and so a test can run the *same* loop rather than a copy of it.
    func makeConsumerTasks(
        services: [SFTPService],
        apply: @escaping @MainActor () -> Void
    ) -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = services.map { service in
            let stream = service.transferUpdates
            return Task { @MainActor [weak self] in
                for await _ in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.pending += 1
                    self.drainedCount += 1
                }
            }
        }

        tasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self, !Task.isCancelled else { return }
                guard self.pending > 0 else { continue }
                self.pending = 0
                self.applyCount += 1
                apply()
            }
        })
        return tasks
    }
}

/// Target-action bridge for the toolbar button.
@MainActor
private final class SFTPTransferRingTarget: NSObject {
    /// Assigned after `super.init()` by `wireUp()`.
    var action: () -> Void = {}
    @objc func invoke() { action() }
}

// MARK: - Popover contents

/// The per-file list behind the ring.
struct SFTPTransferListView: View {
    let i18n: I18n
    /// Live, observable services — not a snapshot.
    let services: [SFTPService]
    let onOpenSFTP: () -> Void

    /// Reads through to the services on every body evaluation, so SwiftUI's own
    /// observation drives this view. Nothing here mutates its own hosting
    /// controller, which is what used to deadlock.
    private var transfers: [SFTPTransfer] {
        services
            .flatMap { service -> [SFTPTransfer] in
                _ = service.transferTick
                return service.transfers
            }
    }

    private var grouped: [(SFTPTransferDirection, [SFTPTransfer])] {
        [SFTPTransferDirection.download, .upload]
            .map { direction in (direction, transfers.filter { $0.direction == direction }) }
            .filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.spacingS) {
            HStack {
                Text(i18n.t(.transfers))
                    .font(.headline)
                Spacer()
                Button(i18n.t(.sftpBrowser), action: onOpenSFTP)
                    .buttonStyle(.link)
            }
            Divider()

            if transfers.isEmpty {
                // Always shows something. An empty popover reads as "clicking is
                // broken", which is a worse failure than saying there is nothing.
                VStack(spacing: AppStyle.spacingS) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.done))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppStyle.spacingM) {
                        ForEach(grouped, id: \.0) { direction, items in
                            VStack(alignment: .leading, spacing: AppStyle.spacingXS) {
                                sectionHeader(direction, items.count)
                                ForEach(items) { row(for: $0) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(AppStyle.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sectionHeader(_ direction: SFTPTransferDirection, _ count: Int) -> some View {
        Label {
            Text("\(direction == .upload ? i18n.t(.upload) : i18n.t(.download)) ×\(count)")
                .font(.system(size: AppStyle.fontSmall, weight: .semibold))
        } icon: {
            Image(systemName: direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(direction == .upload ? .orange : .blue)
        }
    }

    private func row(for transfer: SFTPTransfer) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.spacingXXS) {
            HStack {
                // Truncating rather than a fixed width: filenames run from a few
                // characters to hundreds, and a fixed name width pushes the size
                // off the edge.
                Text(transfer.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AppStyle.spacingXS)
                Text(percent(transfer))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: transfer.fraction)
                .progressViewStyle(.linear)
        }
    }

    private func percent(_ transfer: SFTPTransfer) -> String {
        guard let total = transfer.totalBytes, total > 0 else { return "" }
        return (Double(transfer.transferredBytes) / Double(total))
            .formatted(.percent.precision(.fractionLength(0)))
    }
}