//
//  LightTheme.swift
//  GhostShell
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
            RGBAColor(0.00, 0.00, 0.00),
            RGBAColor(0.80, 0.15, 0.10),
            RGBAColor(0.15, 0.65, 0.25),
            RGBAColor(0.75, 0.55, 0.00),
            RGBAColor(0.15, 0.35, 0.75),
            RGBAColor(0.65, 0.20, 0.65),
            RGBAColor(0.15, 0.55, 0.60),
            RGBAColor(0.70, 0.70, 0.70),
            RGBAColor(0.45, 0.45, 0.45),
            RGBAColor(0.80, 0.15, 0.10),
            RGBAColor(0.15, 0.65, 0.25),
            RGBAColor(0.75, 0.55, 0.00),
            RGBAColor(0.15, 0.35, 0.75),
            RGBAColor(0.65, 0.20, 0.65),
            RGBAColor(0.15, 0.55, 0.60),
            RGBAColor(0.95, 0.95, 0.95),
        ]
    )
}
