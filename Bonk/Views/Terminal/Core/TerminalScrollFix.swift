//
//  TerminalScrollFix.swift
//  Bonk
//
//  Disabled — all scrolling handled natively by SwiftTerm.
//  Previously intercepted ALTBUF scroll events, but caused conflicts
//  with vim mouse reporting and system scroll settings (mos).
//

#if os(macOS)
    import AppKit
    import os.log
    import SwiftTerm

    enum TerminalScrollFix {
        static func register(_ view: TerminalView) {
            // No-op — SwiftTerm handles all scrolling natively
        }

        static func unregister(_ view: TerminalView) {
            // No-op
        }

        static func install() {
            // No-op — SwiftTerm handles all scrolling natively
            Log.ui.info("TerminalScrollFix: using native scrolling")
        }

        static func uninstall() {}
    }
#endif
