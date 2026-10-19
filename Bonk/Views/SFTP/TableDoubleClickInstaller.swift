//
//  TableDoubleClickInstaller.swift
//  Bonk
//
//  Double-click on a SwiftUI List row, without a per-row tap gesture.
//
//  A gesture on every row waits out the system double-click interval before
//  the highlight lands, and it rebuilds the row on the way into a folder.
//  NSTableView.doubleAction selects on the first mouseDown and opens on the
//  second, which is what Finder does.
//

import AppKit
import SwiftUI

struct TableDoubleClickInstaller: NSViewRepresentable {
    var onRow: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRow: onRow)
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onTable = { table in
            table.target = context.coordinator
            table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        context.coordinator.onRow = onRow
        probe.attachIfNeeded()
    }

    final class Coordinator: NSObject {
        var onRow: (Int) -> Void
        init(onRow: @escaping (Int) -> Void) { self.onRow = onRow }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table = sender as? NSTableView else { return }
            let row = table.clickedRow
            guard row >= 0 else { return }
            onRow(row)
        }
    }

    final class Probe: NSView {
        var onTable: ((NSTableView) -> Void)?
        private weak var attached: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        override func layout() {
            super.layout()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard let table = nearestTable(), table !== attached else { return }
            attached = table
            onTable?(table)
        }

        /// The list's table is a sibling a level or two up, not an ancestor.
        /// Stop after a few levels so a window with two file lists does not
        /// hand this installer the other pane's table.
        private func nearestTable() -> NSTableView? {
            var node = superview
            var levels = 0
            while let current = node, levels < 4 {
                if let table = current as? NSTableView { return table }
                if let table = Self.firstTable(in: current, skipping: self) { return table }
                node = current.superview
                levels += 1
            }
            return nil
        }

        private static func firstTable(in view: NSView, skipping: NSView) -> NSTableView? {
            for subview in view.subviews where subview !== skipping {
                if let table = subview as? NSTableView { return table }
                if let table = firstTable(in: subview, skipping: skipping) { return table }
            }
            return nil
        }
    }
}
