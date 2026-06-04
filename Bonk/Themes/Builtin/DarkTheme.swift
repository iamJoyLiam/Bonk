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
        foreground: RGBAColor(0.941, 0.941, 0.941),   // #f0f0f0 — bright, easy on eyes
        cursor: RGBAColor(0.941, 0.941, 0.941),
        ansiColors: SharedColors.darkANSI
    )
}

/// ANSI colors shared by dark-based themes (dark, transparent, etc.)
enum SharedColors {
    static let darkANSI: [RGBAColor] = [
        RGBAColor(0.118, 0.118, 0.118),  // black       #1e1e1e
        RGBAColor(0.871, 0.439, 0.439),  // red          #de7070
        RGBAColor(0.545, 0.820, 0.529),  // green        #8bd187
        RGBAColor(0.878, 0.745, 0.471),  // yellow       #e0be78
        RGBAColor(0.490, 0.678, 0.922),  // blue         #7daeeb — vivid, easy to see
        RGBAColor(0.749, 0.569, 0.922),  // magenta      #bf91eb
        RGBAColor(0.490, 0.784, 0.843),  // cyan         #7dc8d7
        RGBAColor(0.941, 0.941, 0.941),  // white        #f0f0f0
        RGBAColor(0.451, 0.451, 0.451),  // bright black #737373
        RGBAColor(0.922, 0.533, 0.533),  // bright red   #eb8888
        RGBAColor(0.647, 0.882, 0.627),  // bright green #a5e1a0
        RGBAColor(0.941, 0.824, 0.569),  // bright yellow#f0d291
        RGBAColor(0.608, 0.784, 0.961),  // bright blue  #9bc8f5
        RGBAColor(0.843, 0.686, 0.961),  // bright magenta#d7aff5
        RGBAColor(0.608, 0.863, 0.902),  // bright cyan  #9bdce6
        RGBAColor(0.980, 0.980, 0.980),  // bright white #fafafa
    ]
}
