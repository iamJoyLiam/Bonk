//
//  BonkWindowToolbar.swift
//  Bonk
//
//  NSViewRepresentable that replaces window toolbar with customizable NSToolbar.
//

#if os(macOS)
import AppKit
import SwiftUI

struct BonkWindowToolbar: NSViewRepresentable {
    let coordinator: ToolbarCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(coordinator: coordinator)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            // Create toolbar with unique identifier (like MarkEdit)
            let toolbar = NSToolbar(identifier: "com.bonk.mainWindowToolbar")
            toolbar.delegate = context.coordinator.delegate
            toolbar.allowsUserCustomization = true
            toolbar.autosavesConfiguration = true
            toolbar.displayMode = .iconOnly

            // Replace window's toolbar completely
            window.toolbar = toolbar
            window.toolbar?.validateVisibleItems()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Coordinator

extension BonkWindowToolbar {
    final class Coordinator {
        let delegate: BonkToolbarDelegate
        init(coordinator: ToolbarCoordinator) {
            self.delegate = BonkToolbarDelegate(coordinator: coordinator)
        }
    }
}
#endif
