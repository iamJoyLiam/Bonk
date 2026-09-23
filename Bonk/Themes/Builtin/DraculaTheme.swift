//
//  DraculaTheme.swift
//  Bonk
//
//  Dracula theme - dark theme with purple accents.
//  Official ANSI palette per Dracula spec (draculatheme.com/spec).
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
        foreground: RGBAColor(0.973, 0.973, 0.949), // #f8f8f2
        cursor: RGBAColor(0.973, 0.973, 0.949), // #f8f8f2
        ansiColors: [
            RGBAColor(0.129, 0.133, 0.173), // black          #21222c
            RGBAColor(1.000, 0.333, 0.333), // red            #ff5555
            RGBAColor(0.314, 0.980, 0.482), // green          #50fa7b
            RGBAColor(0.945, 0.980, 0.549), // yellow         #f1fa8c
            RGBAColor(0.741, 0.576, 0.976), // blue           #bd93f9
            RGBAColor(1.000, 0.475, 0.776), // magenta        #ff79c6
            RGBAColor(0.545, 0.914, 0.992), // cyan           #8be9fd
            RGBAColor(0.973, 0.973, 0.949), // white          #f8f8f2
            RGBAColor(0.384, 0.447, 0.643), // bright black   #6272a4
            RGBAColor(1.000, 0.431, 0.431), // bright red     #ff6e6e
            RGBAColor(0.412, 1.000, 0.580), // bright green   #69ff94
            RGBAColor(1.000, 1.000, 0.647), // bright yellow  #ffffa5
            RGBAColor(0.839, 0.675, 1.000), // bright blue    #d6acff
            RGBAColor(1.000, 0.573, 0.875), // bright magenta #ff92df
            RGBAColor(0.643, 1.000, 1.000), // bright cyan    #a4ffff
            RGBAColor(1.000, 1.000, 1.000), // bright white   #ffffff
        ]
    )
}
