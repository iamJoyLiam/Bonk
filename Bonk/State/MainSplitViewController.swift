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
import os.log
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
    private var inspectorObservationTask: Task<Void, Never>?
    private var collapsedObservation: NSKeyValueObservation?

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
        updateInspectorVisibility()
        installSidebarAppearanceRefresh()
    }

    /// macOS 26's sidebar glass draws its shadow once with square corners when
    /// the window state changes (resign key / sidebar collapse). Force an
    /// immediate redraw so the shadow follows the window's rounded corners.
    private func installSidebarAppearanceRefresh() {
        let refresh: (Notification) -> Void = { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let window = note.object as? NSWindow,
                      window === self.view.window
                else { return }
                self.refreshSidebarAppearance()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main,
            using: refresh
        )
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main,
            using: refresh
        )
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSSplitViewDidCollapseSubviewNotification"), object: splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSidebarAppearance() }
        }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSSplitViewDidExpandSubviewNotification"), object: splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSidebarAppearance() }
        }
    }

    private func refreshSidebarAppearance() {
        splitView.needsDisplay = true
        splitView.needsLayout = true
        splitView.subviews.forEach { sub in
            sub.needsDisplay = true
            sub.layer?.setNeedsDisplay()
        }
        view.window?.contentView?.needsDisplay = true
        CATransaction.flush()
    }

    // MARK: - Inspector Visibility

    /// The inspector's visibility follows `workspace.activeRightPanel`
    /// (same behavior as the old `.inspector(isPresented:)`).
    private func startInspectorObservation() {
        inspectorObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.workspace.activeRightPanel
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self.updateInspectorVisibility()
            }
        }

        // Collapsing the inspector by hand resets the active panel.
        collapsedObservation = inspectorSplitItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let item = self.inspectorSplitItem, item.isCollapsed, self.workspace.activeRightPanel != .none else { return }
                self.workspace.activeRightPanel = .none
            }
        }
    }

    private func updateInspectorVisibility() {
        let shouldShow = workspace.activeRightPanel != .none
        if inspectorSplitItem.isCollapsed == shouldShow {
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
