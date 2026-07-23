//
//  TerminalScrollFix.swift
//  Bonk
//
//  Terminal registration helper only.
//  Scrolling is handled natively by SwiftTerm's scrollSensitivity.
//

#if os(macOS)
    import AppKit
    import os.log
    import SwiftTerm

    enum TerminalScrollFix {
        static func register(_ view: TerminalView) {
            // No-op — SwiftTerm handles scrolling natively
        }

        static func unregister(_ view: TerminalView) {
            // No-op
        }

        static func install() {
            Log.ui.info("TerminalScrollFix: using native SwiftTerm scrolling")
        }

        static func uninstall() {}
    }
#endif
