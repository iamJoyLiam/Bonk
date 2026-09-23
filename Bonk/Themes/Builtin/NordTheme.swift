//
//  NordTheme.swift
//  Bonk
//
//  Nord theme - arctic, north-bluish color palette.
//  Official Nord palette mapping for terminal ports (nordtheme.com). Bright red/green/yellow/blue/magenta intentionally match normal per Nord convention.
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
            RGBAColor(0.231, 0.259, 0.322), // black          #3b4252
            RGBAColor(0.749, 0.380, 0.416), // red            #bf616a
            RGBAColor(0.639, 0.745, 0.549), // green          #a3be8c
            RGBAColor(0.922, 0.796, 0.545), // yellow         #ebcb8b
            RGBAColor(0.506, 0.631, 0.757), // blue           #81a1c1
            RGBAColor(0.706, 0.557, 0.678), // magenta        #b48ead
            RGBAColor(0.533, 0.753, 0.816), // cyan           #88c0d0
            RGBAColor(0.898, 0.914, 0.941), // white          #e5e9f0
            RGBAColor(0.298, 0.337, 0.416), // bright black   #4c566a
            RGBAColor(0.749, 0.380, 0.416), // bright red     #bf616a
            RGBAColor(0.639, 0.745, 0.549), // bright green   #a3be8c
            RGBAColor(0.922, 0.796, 0.545), // bright yellow  #ebcb8b
            RGBAColor(0.506, 0.631, 0.757), // bright blue    #81a1c1
            RGBAColor(0.706, 0.557, 0.678), // bright magenta #b48ead
            RGBAColor(0.561, 0.737, 0.733), // bright cyan    #8fbcbb
            RGBAColor(0.925, 0.937, 0.957), // bright white   #eceff4
        ]
    )
}
