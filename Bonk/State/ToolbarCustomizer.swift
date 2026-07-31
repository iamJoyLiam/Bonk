//
//  ToolbarCustomizer.swift
//  Bonk
//
//  Enables toolbar customization via ObjC runtime.
//

#if os(macOS)
import AppKit
import SwiftUI
import ObjectiveC

// MARK: - Customizer

@MainActor
final class ToolbarCustomizer {

    /// Enable toolbar customization by setting identifier + allowsUserCustomization.
    /// The assertion fires when identifier is empty. We set it via ivar first.
    static func enable(on window: NSWindow?) {
        guard let window, let toolbar = window.toolbar else { return }

        // Step 1: Set _toolbarIdentifier via ivar (the real ivar name is _toolbarIdentifier)
        if let ivar = class_getInstanceVariable(NSToolbar.self, "_toolbarIdentifier") {
            let currentId = object_getIvar(toolbar, ivar) as? String
            if currentId == nil || currentId?.isEmpty == true {
                object_setIvar(toolbar, ivar, "com.bonk.mainToolbar" as NSString)
            }
        }

        // Step 2: Now set allowsUserCustomization (assertion should pass with valid identifier)
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
    }
}

// MARK: - SwiftUI View

struct ToolbarCustomizerView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Wait for window to be fully loaded and sized
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ToolbarCustomizer.enable(on: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
