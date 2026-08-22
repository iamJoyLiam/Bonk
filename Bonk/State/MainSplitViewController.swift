//
//  MainSplitViewController.swift
//  Bonk
//
//  NSSplitViewController shell replacing SwiftUI's NavigationSplitView,
//  following TablePro's architecture. Three panes host SwiftUI content:
//  sidebar (HostListView), detail (ContentView), inspector
//  (InspectorContainerView). Serving as window.contentViewController keeps
//  `.toggleSidebar` and `.sidebarTrackingSeparator` working through the
//  responder chain, and SwiftUI no longer contributes any window toolbar.
//

import AppKit
import SwiftData
import SwiftUI

@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let workspace: WorkspaceManager
    private let sessionManager: SessionManager
    private let i18n: I18n
    private let coordinator: ToolbarCoordinator
    private let modelContainer: ModelContainer

    private var inspectorSplitItem: NSSplitViewItem!
    private var collapsedObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    init(
        workspace: WorkspaceManager,
        sessionManager: SessionManager,
        i18n: I18n,
        coordinator: ToolbarCoordinator,
        modelContainer: ModelContainer
    ) {
        self.workspace = workspace
        self.sessionManager = sessionManager
        self.i18n = i18n
        self.coordinator = coordinator
        self.modelContainer = modelContainer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainSplitViewController does not support NSCoder init")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let locale = Locale(identifier: i18n.lang)

        // Sidebar
        let sidebarHosting = NSHostingController(
            rootView: SidebarHostView(sessionManager: sessionManager)
                .environment(i18n)
                .environment(workspace)
                .environment(\.locale, locale)
                .modelContainer(modelContainer)
        )
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
        addSplitViewItem(sidebarItem)

        // Detail
        let detailHosting = NSHostingController(
            rootView: ContentView(sessionManager: sessionManager, toolbarCoordinator: coordinator)
                .environment(i18n)
                .environment(workspace)
                .environment(\.locale, locale)
                .modelContainer(modelContainer)
        )
        detailHosting.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.minimumThickness = 400
        detailItem.holdingPriority = .defaultLow
        addSplitViewItem(detailItem)

        // Inspector
        let inspectorHosting = NSHostingController(
            rootView: InspectorContainerView(sessionManager: sessionManager)
                .environment(i18n)
                .environment(workspace)
                .environment(\.locale, locale)
                .modelContainer(modelContainer)
        )
        inspectorHosting.sizingOptions = []
        inspectorSplitItem = NSSplitViewItem(inspectorWithViewController: inspectorHosting)
        inspectorSplitItem.canCollapse = true
        inspectorSplitItem.minimumThickness = 280
        inspectorSplitItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        inspectorSplitItem.isCollapsed = true
        addSplitViewItem(inspectorSplitItem)

        splitView.autosaveName = "BonkMainSplit"
        startInspectorObservation()
        updateInspectorVisibility(animated: false)
        installSidebarAppearanceRefresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Re-assert after the split view's autosaved collapse state is
        // restored, so the inspector never starts open but empty.
        updateInspectorVisibility(animated: false)
    }

    /// macOS 26's sidebar glass draws its shadow once with square corners when
    /// the window state changes (resign key / sidebar collapse). Force an
    /// immediate redraw so the shadow follows the window's rounded corners.
    private func installSidebarAppearanceRefresh() {
        let refresh: @Sendable (Notification) -> Void = { [weak self] note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let self,
                      let window = object as? NSWindow,
                      window === self.view.window
                else { return }
                self.refreshSidebarAppearance()
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main,
            using: refresh
        ))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main,
            using: refresh
        ))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSSplitViewDidCollapseSubviewNotification"), object: splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSidebarAppearance() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSSplitViewDidExpandSubviewNotification"), object: splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSidebarAppearance() }
        })
        // Theme changes (View → Theme) update NSApp.appearance; the window was
        // made explicit to fix toolbar ring vibrancy bleed, so it no longer
        // inherits automatically — re-sync here.
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalThemeDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSidebarAppearance() }
        })
        // System appearance toggles when theme is "system" (NSApp.appearance=nil).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSidebarAppearance() }
        })
    }

    private func refreshSidebarAppearance() {
        // Keep window chrome (toolbar rings included) locked to the app theme —
        // sidebar's vibrant material can otherwise leave toolbar items stuck in aqua
        // while NSApp is darkAqua (visible as black-on-black track).
        if let window = view.window, window.appearance != NSApp.appearance {
            window.appearance = NSApp.appearance
        }
        splitView.needsDisplay = true
        splitView.needsLayout = true
        splitView.subviews.forEach { sub in
            sub.needsDisplay = true
            sub.layer?.setNeedsDisplay()
        }
        view.window?.contentView?.needsDisplay = true
        // Toolbar ring views are NSButton-based and cache their appearance at
        // creation; whack them so they redraw with the corrected appearance.
        view.window?.toolbar?.validateVisibleItems()
        // Also nudge any ServerResourceRingControl that is currently visible.
        if let toolbar = view.window?.toolbar {
            for item in toolbar.items where item.view is ServerResourceRingControl {
                item.view?.needsDisplay = true
            }
        }
        CATransaction.flush()
    }

    // MARK: - Inspector Visibility

    /// The inspector's visibility follows `workspace.activeRightPanel`
    /// (same behavior as the old `.inspector(isPresented:)`).
    private func startInspectorObservation() {
        observeActiveRightPanel()

        // Keep the panel selection alive across manual collapse/expand so the
        // content is still there when the user drags the inspector back out.
        collapsedObservation = inspectorSplitItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let item = self.inspectorSplitItem else { return }
                self.workspace.isInspectorCollapsed = item.isCollapsed
            }
        }
    }

    private func observeActiveRightPanel() {
        withObservationTracking {
            _ = workspace.activeRightPanel
        } onChange: { [weak self] in
            // withObservationTracking fires before the write is committed — defer
            // both the UI update and the re-registration to the next runloop.
            Task { @MainActor [weak self] in
                self?.updateInspectorVisibility(animated: true)
                self?.observeActiveRightPanel()
            }
        }
    }

    private func updateInspectorVisibility(animated: Bool) {
        let shouldShow = workspace.activeRightPanel != .none
        guard inspectorSplitItem.isCollapsed == shouldShow else { return }
        if animated {
            inspectorSplitItem.animator().isCollapsed = !shouldShow
        } else {
            inspectorSplitItem.isCollapsed = !shouldShow
        }
    }
}

// MARK: - Sidebar Host

/// Wraps `HostListView` so the sidebar pane can resolve the default SSH port
/// from SwiftData on its own.
private struct SidebarHostView: View {
    @Environment(I18n.self) private var i18n
    @Query private var allPreferences: [UserPreferences]

    let sessionManager: SessionManager

    private var defaultPort: Int {
        allPreferences.first?.defaultPort ?? 22
    }

    var body: some View {
        HostListView(sessionManager: sessionManager, defaultPort: defaultPort)
    }
}
