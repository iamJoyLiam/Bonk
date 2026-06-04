//
//  TransparentTheme.swift
//  GhostShell
//

import Foundation

struct TransparentTheme: TerminalTheme {
    let id = "transparent"
    let name = "Transparent"
    let isDark = true

    /// Default color scheme (will be overridden by colorScheme(opacity:) in practice).
    let colorScheme = TerminalColorScheme(
        id: "transparent",
        name: "Transparent",
        background: RGBAColor(0.118, 0.118, 0.118, 0.85),
        foreground: RGBAColor(0.980, 0.980, 0.980),
        cursor: RGBAColor(0.980, 0.980, 0.980),
        ansiColors: SharedColors.darkANSI
    )

    func colorScheme(opacity: Double) -> TerminalColorScheme {
        let a = max(0.1, min(1.0, opacity))
        return TerminalColorScheme(
            id: "transparent",
            name: "Transparent",
            background: RGBAColor(0.118, 0.118, 0.118, a),
            foreground: RGBAColor(0.980, 0.980, 0.980),
            cursor: RGBAColor(0.980, 0.980, 0.980),
            ansiColors: SharedColors.darkANSI
        )
    }
}
