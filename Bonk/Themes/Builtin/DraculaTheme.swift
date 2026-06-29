//
//  DraculaTheme.swift
//  Bonk
//
//  Dracula theme - dark theme with purple accents.
//

import Foundation

struct DraculaTheme: TerminalTheme {
    let id = "dracula"
    let name = "Dracula"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "dracula",
        name: "Dracula",
        background: RGBAColor(0.157, 0.165, 0.212), // #282a36
        foreground: RGBAColor(0.976, 0.976, 0.949), // #f8f8f2
        cursor: RGBAColor(0.976, 0.976, 0.949), // #f8f8f2
        ansiColors: [
            RGBAColor(0.157, 0.165, 0.212), // black       #282a36
            RGBAColor(1.0, 0.333, 0.333), // red         #ff5555
            RGBAColor(0.314, 0.980, 0.478), // green       #50fa7b
            RGBAColor(1.0, 0.918, 0.412), // yellow      #f1fa8c
            RGBAColor(0.447, 0.647, 1.0), // blue        #6272a4
            RGBAColor(0.788, 0.533, 1.0), // magenta     #bd93f9
            RGBAColor(0.498, 0.933, 0.882), // cyan        #8be9fd
            RGBAColor(0.976, 0.976, 0.949), // white       #f8f8f2
            RGBAColor(0.341, 0.353, 0.416), // bright black #44475a
            RGBAColor(1.0, 0.333, 0.333), // bright red   #ff5555
            RGBAColor(0.314, 0.980, 0.478), // bright green #50fa7b
            RGBAColor(1.0, 0.918, 0.412), // bright yellow#f1fa8c
            RGBAColor(0.447, 0.647, 1.0), // bright blue  #6272a4
            RGBAColor(0.788, 0.533, 1.0), // bright magenta#bd93f9
            RGBAColor(0.498, 0.933, 0.882), // bright cyan  #8be9fd
            RGBAColor(0.976, 0.976, 0.949), // bright white #f8f8f2
        ]
    )
}
