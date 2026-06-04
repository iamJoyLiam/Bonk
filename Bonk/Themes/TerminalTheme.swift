//
//  TerminalTheme.swift
//  Bonk
//
//  Core types for the terminal theme system.
//  Each theme is a separate file conforming to TerminalTheme protocol.
//

import SwiftUI
import SwiftTerm

// MARK: - RGBA Color

/// RGBA color stored as 0–1 floats. Sendable, no platform dependency.
public struct RGBAColor: Sendable, Hashable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(red: r, green: g, blue: b, opacity: a)
    }

    #if os(macOS)
    public var nsColor: NSColor {
        NSColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
    #else
    public var uiColor: UIColor {
        UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
    #endif

    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(r * 65535),
            green: UInt16(g * 65535),
            blue: UInt16(b * 65535)
        )
    }
}

// MARK: - Terminal Color Scheme

/// Concrete color scheme with 16 ANSI colors + foreground/background/cursor.
public struct TerminalColorScheme: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let background: RGBAColor
    public let foreground: RGBAColor
    public let cursor: RGBAColor
    public let ansiColors: [RGBAColor]

    public var isTransparent: Bool { background.a < 1.0 }

    public init(
        id: String,
        name: String,
        background: RGBAColor,
        foreground: RGBAColor,
        cursor: RGBAColor,
        ansiColors: [RGBAColor]
    ) {
        precondition(ansiColors.count == 16, "Need exactly 16 ANSI colors")
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.ansiColors = ansiColors
    }

    public static func == (lhs: TerminalColorScheme, rhs: TerminalColorScheme) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - SwiftTerm Interop

extension TerminalColorScheme {
    var swiftTermColors: [SwiftTerm.Color] {
        ansiColors.map(\.swiftTermColor)
    }
}

// MARK: - Terminal Theme Protocol

/// A terminal theme that can be registered with the ThemeRegistry.
/// Each theme lives in its own file. Plugins conform to this protocol.
protocol TerminalTheme: Sendable {
    var id: String { get }
    var name: String { get }
    var colorScheme: TerminalColorScheme { get }
    /// Whether this is a dark theme. Drives the app chrome (sidebar, settings, window).
    var isDark: Bool { get }
}

/// Extension for themes that need dynamic parameters (e.g., transparency opacity).
extension TerminalTheme {
    /// Default: no dynamic parameters needed.
    func colorScheme(opacity: Double) -> TerminalColorScheme {
        colorScheme
    }
}
