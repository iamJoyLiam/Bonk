//
//  DarkTheme.swift
//  Bonk
//

import Foundation

struct DarkTheme: TerminalTheme {
    let id = "dark"
    let name = "Dark"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "dark",
        name: "Dark",
        background: RGBAColor(0.118, 0.118, 0.118),
        // Body text #e0e0e0. Quiet on the gray glass, so the colors can
        // carry the file types. The cursor stays a brighter mark.
        foreground: RGBAColor(0.878, 0.878, 0.878),
        cursor: RGBAColor(0.941, 0.941, 0.941),
        ansiColors: SharedColors.darkANSI
    )
}

/// ANSI colors shared by dark-based themes
enum SharedColors {
    static let darkANSI: [RGBAColor] = [
        RGBAColor(0.118, 0.118, 0.118), // black        #1e1e1e
        RGBAColor(0.878, 0.541, 0.541), // red          #e08a8a
        RGBAColor(0.498, 0.812, 0.549), // green        #7fcf8c
        RGBAColor(0.886, 0.757, 0.416), // yellow       #e2c16a
        RGBAColor(0.494, 0.714, 0.961), // blue         #7eb6f5
        RGBAColor(0.769, 0.604, 0.878), // magenta      #c49ae0
        RGBAColor(0.369, 0.769, 0.831), // cyan         #5ec4d4
        RGBAColor(0.949, 0.949, 0.949), // white        #f2f2f2
        RGBAColor(0.451, 0.451, 0.451), // bright black #737373
        RGBAColor(0.941, 0.706, 0.706), // bright red   #f0b4b4  archives
        RGBAColor(0.659, 0.894, 0.690), // bright green #a8e4b0
        RGBAColor(0.941, 0.831, 0.549), // bright yellow#f0d48c
        RGBAColor(0.663, 0.788, 0.980), // bright blue  #a9c9fa  directories
        RGBAColor(0.859, 0.722, 0.949), // bright magenta#dbb8f2
        RGBAColor(0.541, 0.863, 0.918), // bright cyan  #8adcea
        RGBAColor(0.969, 0.969, 0.969), // bright white #f7f7f7
    ]
}
