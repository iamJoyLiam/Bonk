//
//  TableDoubleClickHost.swift
//  Bonk
//
//  AppKit-native double-click for a SwiftUI List (NSTableView-backed) without
//  touching single-click selection. Rows carry no SwiftUI tap gestures, and
//  the table's own target/action is never modified (SwiftUI routes its
//  internal tap handling through them). Instead, a dedicated
//  NSClickGestureRecognizer observes double-clicks independently with
//  delaysPrimaryMouseButtonEvents = false, so single clicks are never held
//  back. If the host table cannot be found, double-click is silently
//  unavailable (chevron / Return / menu remain).
//

import AppKit
import SwiftUI

struct TableDoubleClickHost: NSViewRepresentable {
    /// Called on the main thread with the clicked row index on double-click.
    /// Callers must bounds-check the row against their current model.
    var onDoubleClickRow: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DoubleClickHookView()
        view.onAttach = { [weak coordinator = context.coordinator] table in
            coordinator?.attach(to: table)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDoubleClickRow = onDoubleClickRow
        (nsView as? DoubleClickHookView)?.hookupIfNeeded()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Main-thread confined by AppKit contract (gesture actions, table lookup).
    final class Coordinator: NSObject, @unchecked Sendable {
        var onDoubleClickRow: (Int) -> Void = { _ in }

        func attach(to table: NSTableView) {
            if table.gestureRecognizers.contains(where: { $0 is TableDoubleClickRecognizer }) {
                return
            }
            let recognizer = TableDoubleClickRecognizer(target: self, action: #selector(doubleClicked(_:)))
            recognizer.numberOfClicksRequired = 2
            recognizer.delaysPrimaryMouseButtonEvents = false
            recognizer.buttonMask = 0x1 // left button only
            table.addGestureRecognizer(recognizer)
        }

        @objc private func doubleClicked(_ recognizer: NSGestureRecognizer) {
            guard let table = recognizer.view as? NSTableView else { return }
            let row = table.row(at: recognizer.location(in: table))
            guard row >= 0 else { return }
            onDoubleClickRow(row)
        }
    }
}

/// Marker subclass so attach stays idempotent across SwiftUI re-renders.
private final class TableDoubleClickRecognizer: NSClickGestureRecognizer {}

/// Zero-size view placed in the List background; climbs the hierarchy to find
/// the enclosing NSTableView (nearest wins, so dual panes resolve correctly).
private final class DoubleClickHookView: NSView {
    var onAttach: ((NSTableView) -> Void)?
    private weak var hookedTable: NSTableView?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hookupIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hookupIfNeeded()
    }

    func hookupIfNeeded() {
        guard let table = findTable(), table !== hookedTable else { return }
        hookedTable = table
        onAttach?(table)
    }

    private func findTable() -> NSTableView? {
        var view: NSView? = self
        while let current = view {
            if let table = current as? NSTableView {
                return table
            }
            if let found = current.firstDescendant(of: NSTableView.self) {
                return found
            }
            view = current.superview
        }
        return nil
    }
}

private extension NSView {
    /// Bounded depth-first search; depth 6 covers ScrollView > ClipView > Table.
    func firstDescendant<T: NSView>(of type: T.Type, depth: Int = 6) -> T? {
        guard depth > 0 else { return nil }
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let found = subview.firstDescendant(of: type, depth: depth - 1) {
                return found
            }
        }
        return nil
    }
}
