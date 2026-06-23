//
//  TabDragPayload.swift
//  Bonk
//
//  Simple string-based drag payload (no custom UTType needed).
//

import Foundation
#if os(macOS)
    import AppKit
#endif

/// Pasteboard type for tab drag.
let tabDragType = NSPasteboard.PasteboardType("com.bonk.tab-drag")
