//
//  LightTheme.swift
//  Bonk
//

import Foundation

struct LightTheme: TerminalTheme {
    let id = "light"
    let name = "Light"
    let isDark = false

    let colorScheme = TerminalColorScheme(
        id: "light",
        name: "Light",
        background: RGBAColor(1.0, 1.0, 1.0),
        foreground: RGBAColor(0.15, 0.15, 0.15),
        cursor: RGBAColor(0.15, 0.15, 0.15),
        ansiColors: [
            RGBAColor(0.00, 0.00, 0.00), // black
            RGBAColor(0.80, 0.15, 0.10), // red
            RGBAColor(0.10, 0.50, 0.20), // green - darker for better contrast
            RGBAColor(0.60, 0.40, 0.00), // yellow - darker for better contrast
            RGBAColor(0.15, 0.35, 0.75), // blue
            RGBAColor(0.65, 0.20, 0.65), // magenta
            RGBAColor(0.10, 0.40, 0.45), // cyan - darker for better contrast
            RGBAColor(0.40, 0.40, 0.40), // white - darker for better contrast
            RGBAColor(0.45, 0.45, 0.45), // bright black
            RGBAColor(0.80, 0.15, 0.10), // bright red
            RGBAColor(0.10, 0.50, 0.20), // bright green
            RGBAColor(0.60, 0.40, 0.00), // bright yellow
            RGBAColor(0.15, 0.35, 0.75), // bright blue
            RGBAColor(0.65, 0.20, 0.65), // bright magenta
            RGBAColor(0.10, 0.40, 0.45), // bright cyan
            RGBAColor(0.50, 0.50, 0.50), // bright white
        ]
    )
}
