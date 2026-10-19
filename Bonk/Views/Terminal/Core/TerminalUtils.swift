//
//  TerminalUtils.swift
//  Bonk
//
//  Shared utilities for terminal views.
//

import Foundation
import SwiftTerm

// MARK: - Terminal Notifications

extension Notification.Name {
    static let terminalThemeDidChange = Notification.Name("com.bonk.terminalThemeDidChange")
    static let terminalCursorDidChange = Notification.Name("com.bonk.terminalCursorDidChange")
    static let terminalFontDidChange = Notification.Name("com.bonk.terminalFontDidChange")
    static let toggleAIChat = Notification.Name("com.bonk.toggleAIChat")
    static let toggleSFTP = Notification.Name("com.bonk.toggleSFTP")
    static let requestTerminalSelection = Notification.Name("com.bonk.requestTerminalSelection")
    static let terminalSelectionResponse = Notification.Name("com.bonk.terminalSelectionResponse")
    static let selectAllInTerminal = Notification.Name("com.bonk.selectAllInTerminal")
    static let focusTerminal = Notification.Name("com.bonk.focusTerminal")
    static let showCopyMessage = Notification.Name("com.bonk.showCopyMessage")
    static let toggleTerminalSearch = Notification.Name("com.bonk.toggleTerminalSearch")
    static let aiAgentCommandExecuted = Notification.Name("com.bonk.aiAgentCommandExecuted")
    static let terminalNewTab = Notification.Name("com.bonk.terminalNewTab")
    static let terminalCloseTab = Notification.Name("com.bonk.terminalCloseTab")
    static let terminalClosePane = Notification.Name("com.bonk.terminalClosePane")
    static let terminalSplitHorizontal = Notification.Name("com.bonk.terminalSplitHorizontal")
    static let terminalSplitVertical = Notification.Name("com.bonk.terminalSplitVertical")
    static let terminalReconnect = Notification.Name("com.bonk.terminalReconnect")
    static let terminalClear = Notification.Name("com.bonk.terminalClear")
    /// Posted when PTY session is ready and output stream should be connected.
    static let terminalPTYSessionReady = Notification.Name("com.bonk.terminalPTYSessionReady")
}

/// Map cursor style string to SwiftTerm CursorStyle.
func mapCursorStyle(_ style: String, blink: Bool) -> SwiftTerm.CursorStyle {
    switch style {
    case "underline": blink ? .blinkUnderline : .steadyUnderline
    case "bar": blink ? .blinkBar : .steadyBar
    default: blink ? .blinkBlock : .steadyBlock
    }
}

/// Apply color scheme to a terminal view.
@MainActor
func applyColorScheme(to view: SwiftTerm.TerminalView, scheme: TerminalColorScheme) {
    view.nativeBackgroundColor = scheme.background.nsColor
    view.nativeForegroundColor = scheme.foreground.nsColor
    view.installColors(scheme.swiftTermColors)
}

#if os(macOS)
    import AppKit

    /// Inset of the terminal view within its container.
    /// Restored to (4, 8) for comfortable padding; container background now matches
    /// `colorScheme.background` (see TerminalContainerView/PaneContainerBridge) so
    /// the inset no longer appears as a contrasting "box".
    let terminalViewInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    /// The view `NSViewRepresentable` returns for a terminal.
    ///
    /// SwiftUI's representable wrapper is opaque black for the first frames
    /// after a connection replaces the connecting placeholder with this host.
    /// The terminal grid does not cover the leftover strip under the last row,
    /// and the 4pt inset is the wrapper, so that black reads as a bar along
    /// the bottom and then vanishes once the real background composites.
    final class TerminalHostView: NSView {
        var fillColor: NSColor {
            didSet { applyFill() }
        }

        /// Matches the SwiftUI card. Zero leaves this host square, which is
        /// what the non-card containers (the Quake panel) still want.
        var cornerRadius: CGFloat = 0 {
            didSet { applyFill() }
        }

        /// A title bar occupies the card's top, so only the bottom of this
        /// host is an outer corner.
        var roundsTopCorners = true {
            didSet { applyFill() }
        }

        init(fill: NSColor) {
            fillColor = fill
            super.init(frame: .zero)
            wantsLayer = true
            applyFill()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyFill()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyFill()
        }

        private func applyFill() {
            wantsLayer = true
            clipsToBounds = cornerRadius > 0
            layer?.isOpaque = fillColor.cgColor.alpha >= 1 && cornerRadius == 0
            layer?.backgroundColor = fillColor.cgColor
            layer?.cornerRadius = cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = cornerRadius > 0
            layer?.maskedCorners = roundsTopCorners
                ? [
                    .layerMinXMinYCorner, .layerMaxXMinYCorner,
                    .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
                ]
                : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            // SwiftUI's clip does not mask this AppKit view. The rounded
            // layer is what keeps the grid inside the card.
            // The superview used to be painted too, which put a square slab
            // over the card corners. It only needs to stop being black.
            superview?.wantsLayer = true
            superview?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    /// Create a monospaced font, falling back to the system font when the
    /// requested family is unavailable.
    func createSafeFont(family: String, size: CGFloat) -> NSFont {
        guard !family.isEmpty, family != "SF Mono" else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        guard let targetFont = NSFont(name: family, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return targetFont
    }
#endif
