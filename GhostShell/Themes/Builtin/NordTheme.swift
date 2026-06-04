//
//  NordTheme.swift
//  GhostShell
//

import Foundation

struct NordTheme: TerminalTheme {
    let id = "nord"
    let name = "Nord"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "nord",
        name: "Nord",
        background: RGBAColor(0.180, 0.204, 0.251),
        foreground: RGBAColor(0.847, 0.871, 0.914),
        cursor: RGBAColor(0.847, 0.871, 0.914),
        ansiColors: [
            RGBAColor(0.180, 0.204, 0.251),
            RGBAColor(0.749, 0.380, 0.420),
            RGBAColor(0.506, 0.722, 0.478),
            RGBAColor(0.843, 0.725, 0.459),
            RGBAColor(0.396, 0.576, 0.757),
            RGBAColor(0.659, 0.490, 0.722),
            RGBAColor(0.424, 0.694, 0.741),
            RGBAColor(0.847, 0.871, 0.914),
            RGBAColor(0.333, 0.369, 0.439),
            RGBAColor(0.749, 0.380, 0.420),
            RGBAColor(0.506, 0.722, 0.478),
            RGBAColor(0.843, 0.725, 0.459),
            RGBAColor(0.396, 0.576, 0.757),
            RGBAColor(0.659, 0.490, 0.722),
            RGBAColor(0.424, 0.694, 0.741),
            RGBAColor(0.925, 0.937, 0.957),
        ]
    )
}
