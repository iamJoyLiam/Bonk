//
//  SolarizedDarkTheme.swift
//  Bonk
//
//  Solarized Dark theme - easy on the eyes, popular among developers.
//  Official Solarized palette (ethanschoonover.com/solarized).
//

import Foundation

struct SolarizedDarkTheme: TerminalTheme {
    let id = "solarized-dark"
    let name = "Solarized Dark"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        background: RGBAColor(0.000, 0.169, 0.212), // #002b36
        foreground: RGBAColor(0.514, 0.580, 0.588), // #839496
        cursor: RGBAColor(0.514, 0.580, 0.588), // #839496
        ansiColors: [
            RGBAColor(0.027, 0.212, 0.259), // black          #073642
            RGBAColor(0.863, 0.196, 0.184), // red            #dc322f
            RGBAColor(0.522, 0.600, 0.000), // green          #859900
            RGBAColor(0.710, 0.537, 0.000), // yellow         #b58900
            RGBAColor(0.149, 0.545, 0.824), // blue           #268bd2
            RGBAColor(0.827, 0.212, 0.510), // magenta        #d33682
            RGBAColor(0.165, 0.631, 0.596), // cyan           #2aa198
            RGBAColor(0.933, 0.910, 0.835), // white          #eee8d5
            RGBAColor(0.396, 0.482, 0.514), // bright black   #657b83
            RGBAColor(0.863, 0.196, 0.184), // bright red     #dc322f
            RGBAColor(0.522, 0.600, 0.000), // bright green   #859900
            RGBAColor(0.710, 0.537, 0.000), // bright yellow  #b58900
            RGBAColor(0.149, 0.545, 0.824), // bright blue    #268bd2
            RGBAColor(0.424, 0.443, 0.769), // bright magenta #6c71c4
            RGBAColor(0.165, 0.631, 0.596), // bright cyan    #2aa198
            RGBAColor(0.992, 0.965, 0.890), // bright white   #fdf6e3
        ]
    )
}

// Intentional deviation from canonical Solarized mapping: canonical brightBlack/base03 equals the Dark background and becomes visually indistinguishable in terminal usage; Bonk uses base00 (#657B83) instead to preserve visible ANSI bright-black semantics.
