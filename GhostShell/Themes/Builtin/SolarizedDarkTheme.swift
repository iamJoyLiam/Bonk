//
//  SolarizedDarkTheme.swift
//  GhostShell
//

import Foundation

struct SolarizedDarkTheme: TerminalTheme {
    let id = "solarized-dark"
    let name = "Solarized Dark"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        background: RGBAColor(0.0, 0.169, 0.212),
        foreground: RGBAColor(0.514, 0.580, 0.588),
        cursor: RGBAColor(0.514, 0.580, 0.588),
        ansiColors: [
            RGBAColor(0.027, 0.212, 0.259),
            RGBAColor(0.863, 0.196, 0.184),
            RGBAColor(0.522, 0.600, 0.000),
            RGBAColor(0.710, 0.537, 0.000),
            RGBAColor(0.149, 0.545, 0.824),
            RGBAColor(0.827, 0.212, 0.514),
            RGBAColor(0.165, 0.631, 0.596),
            RGBAColor(0.580, 0.631, 0.631),
            RGBAColor(0.000, 0.169, 0.212),
            RGBAColor(0.863, 0.196, 0.184),
            RGBAColor(0.522, 0.600, 0.000),
            RGBAColor(0.710, 0.537, 0.000),
            RGBAColor(0.149, 0.545, 0.824),
            RGBAColor(0.827, 0.212, 0.514),
            RGBAColor(0.165, 0.631, 0.596),
            RGBAColor(0.933, 0.910, 0.835),
        ]
    )
}
