//
//  ScreenManager.swift
//  Bonk
//
//  Multi-display support for Quake window positioning.
//

import AppKit

// MARK: - Screen Manager

/// Manages screen detection and frame calculations for Quake window.
struct ScreenManager {

    /// Get the screen where the mouse cursor is currently located.
    static func screenForMouseLocation() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        }
    }

    /// Get the visible frame (excluding menu bar and dock) for the current screen.
    static func visibleFrameForCurrentScreen() -> CGRect {
        screenForMouseLocation()?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    /// Calculate Quake window frame based on configuration.
    /// - Parameters:
    ///   - heightRatio: Height as ratio of screen height (0.0 - 1.0)
    ///   - widthRatio: Width as ratio of screen width (0.0 - 1.0)
    /// - Returns: The target frame for the Quake window.
    static func quakeFrame(heightRatio: CGFloat = 0.5, widthRatio: CGFloat = 1.0) -> CGRect {
        let screenFrame = visibleFrameForCurrentScreen()

        let windowWidth = screenFrame.width * widthRatio
        let windowHeight = screenFrame.height * heightRatio
        let windowX = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let windowY = screenFrame.origin.y + screenFrame.height - windowHeight

        return CGRect(
            x: windowX,
            y: windowY,
            width: windowWidth,
            height: windowHeight
        )
    }

    /// Calculate hidden frame (above screen, for slide-in animation).
    static func hiddenFrame(heightRatio: CGFloat = 0.5, widthRatio: CGFloat = 1.0) -> CGRect {
        let visibleFrame = visibleFrameForCurrentScreen()
        let targetFrame = quakeFrame(heightRatio: heightRatio, widthRatio: widthRatio)

        return CGRect(
            x: targetFrame.origin.x,
            y: visibleFrame.origin.y + visibleFrame.height,
            width: targetFrame.width,
            height: targetFrame.height
        )
    }
}
