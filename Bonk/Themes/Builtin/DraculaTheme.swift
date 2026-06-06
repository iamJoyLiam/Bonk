//
//  DraculaTheme.swift
//  Bonk
//

import Foundation

struct DraculaTheme: TerminalTheme {
    let id = "dracula"
    let name = "Dracula"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "dracula",
        name: "Dracula",
        background: RGBAColor(0.157, 0.165, 0.212),
        foreground: RGBAColor(0.976, 0.976, 0.949),
        cursor: RGBAColor(0.976, 0.976, 0.949),
        ansiColors: [
            RGBAColor(0.157, 0.165, 0.212),
            RGBAColor(1.000, 0.333, 0.333),
            RGBAColor(0.314, 0.980, 0.478),
            RGBAColor(1.000, 0.918, 0.412),
            RGBAColor(0.447, 0.647, 1.000),
            RGBAColor(0.788, 0.533, 1.000),
            RGBAColor(0.498, 0.933, 0.882),
            RGBAColor(0.976, 0.976, 0.949),
            RGBAColor(0.341, 0.353, 0.416),
            RGBAColor(1.000, 0.333, 0.333),
            RGBAColor(0.314, 0.980, 0.478),
            RGBAColor(1.000, 0.918, 0.412),
            RGBAColor(0.447, 0.647, 1.000),
            RGBAColor(0.788, 0.533, 1.000),
            RGBAColor(0.498, 0.933, 0.882),
            RGBAColor(0.976, 0.976, 0.949)
        ]
    )
}
