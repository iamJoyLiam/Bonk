import SwiftUI

enum ThemeManager {
    static func apply(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: "app_themeMode")
        #if os(macOS)
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
        #endif
    }
}
