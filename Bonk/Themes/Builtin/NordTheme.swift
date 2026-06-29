//
//  NordTheme.swift
//  Bonk
//
//  Nord theme - arctic, north-bluish color palette.
//

import Foundation

struct NordTheme: TerminalTheme {
    let id = "nord"
    let name = "Nord"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "nord",
        name: "Nord",
        background: RGBAColor(0.180, 0.204, 0.251), // #2e3440
        foreground: RGBAColor(0.847, 0.871, 0.914), // #d8dee9
        cursor: RGBAColor(0.847, 0.871, 0.914), // #d8dee9
        ansiColors: [
            RGBAColor(0.180, 0.204, 0.251), // black       #2e3440
            RGBAColor(0.749, 0.333, 0.333), // red         #bf616a
            RGBAColor(0.596, 0.737, 0.416), // green       #a3be8c
            RGBAColor(0.776, 0.647, 0.396), // yellow      #ebcb8b
            RGBAColor(0.506, 0.631, 0.757), // blue        #81a1c1
            RGBAColor(0.667, 0.506, 0.733), // magenta     #b48ead
            RGBAColor(0.490, 0.714, 0.757), // cyan        #88c0d0
            RGBAColor(0.847, 0.871, 0.914), // white       #d8dee9
            RGBAColor(0.396, 0.439, 0.514), // bright black #4c566a
            RGBAColor(0.749, 0.333, 0.333), // bright red   #bf616a
            RGBAColor(0.596, 0.737, 0.416), // bright green #a3be8c
            RGBAColor(0.776, 0.647, 0.396), // bright yellow#ebcb8b
            RGBAColor(0.506, 0.631, 0.757), // bright blue  #81a1c1
            RGBAColor(0.667, 0.506, 0.733), // bright magenta#b48ead
            RGBAColor(0.490, 0.714, 0.757), // bright cyan  #88c0d0
            RGBAColor(0.937, 0.949, 0.961), // bright white #eceff4
        ]
    )
}
