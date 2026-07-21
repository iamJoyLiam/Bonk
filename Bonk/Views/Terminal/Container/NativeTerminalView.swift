//
//  NativeTerminalView.swift
//  Bonk
//
//  Intercepts AppKit's physical layout cycle to capture accurate terminal dimensions.
//  Eliminates SwiftUI lifecycle timing issues that cause Vim half-screen rendering.
//

import os
import SwiftTerm

#if os(macOS)
    import AppKit

    /// Custom TerminalView that intercepts AppKit's physical layout completion.
    /// Only fires PTY sync when the system has finalized pixel-level frame calculation.
    class NativeTerminalView: SwiftTerm.TerminalView {
        /// Called when AppKit completes physical layout with accurate cols/rows.
        var onPhysicalLayout: ((Int, Int) -> Void)?

        private var lastSyncedCols = -1
        private var lastSyncedRows = -1

        override func layout() {
            super.layout()

            let cols = self.terminal.cols
            let rows = self.terminal.rows

            // Block invalid zero-value sizes (e.g., when tab is hidden)
            guard cols > 0, rows > 0 else { return }

            // Filter duplicate dimensions to avoid redundant SIGWINCH signals
            guard cols != lastSyncedCols || rows != lastSyncedRows else { return }

            lastSyncedCols = cols
            lastSyncedRows = rows

            // At this point, AppKit has finalized the frame — dimensions are 100% accurate
            onPhysicalLayout?(cols, rows)
        }
    }

#endif
