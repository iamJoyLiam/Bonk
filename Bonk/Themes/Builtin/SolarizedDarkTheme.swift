//
//  SolarizedDarkTheme.swift
//  Bonk
//
//  Solarized Dark theme - easy on the eyes, popular among developers.
//

import Foundation

struct SolarizedDarkTheme: TerminalTheme {
    let id = "solarized-dark"
    let name = "Solarized Dark"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        background: RGBAColor(0.0, 0.169, 0.212), // #002b36
        foreground: RGBAColor(0.514, 0.580, 0.588), // #839496
        cursor: RGBAColor(0.514, 0.580, 0.588), // #839496
        ansiColors: [
            RGBAColor(0.027, 0.212, 0.259), // black       #073642
            RGBAColor(0.863, 0.196, 0.184), // red         #dc322f
            RGBAColor(0.522, 0.600, 0.0), // green       #859900
            RGBAColor(0.710, 0.537, 0.0), // yellow      #b58900
            RGBAColor(0.267, 0.533, 0.682), // blue        #268bd2
            RGBAColor(0.733, 0.333, 0.733), // magenta     #6c71c4
            RGBAColor(0.333, 0.667, 0.667), // cyan        #2aa198
            RGBAColor(0.576, 0.631, 0.631), // white       #93a1a1
            RGBAColor(0.396, 0.482, 0.514), // bright black #657b83
            RGBAColor(0.863, 0.196, 0.184), // bright red   #dc322f
            RGBAColor(0.522, 0.600, 0.0), // bright green #859900
            RGBAColor(0.710, 0.537, 0.0), // bright yellow#b58900
            RGBAColor(0.267, 0.533, 0.682), // bright blue  #268bd2
            RGBAColor(0.733, 0.333, 0.733), // bright magenta#6c71c4
            RGBAColor(0.333, 0.667, 0.667), // bright cyan  #2aa198
            RGBAColor(0.804, 0.859, 0.859), // bright white #fdf6e3
        ]
    )
}
