import Foundation

// MARK: - Static facade for non-SwiftUI contexts

// SwiftUI views should use @EnvironmentObject var i18n: I18n instead.

enum L {
    static var lang: String {
        I18n.shared.lang
    }

    static func t(_ key: LKey) -> String {
        I18n.shared.t(key)
    }

    static func tr(_ key: LKey, args: CVarArg...) -> String {
        let template = I18n.shared.t(key)
        return withVaList(args) { NSString(format: template, arguments: $0) as String }
    }

    static var availableLanguages: [String] {
        I18n.shared.availableLanguages
    }

    static func displayName(for code: String) -> String {
        I18n.shared.displayName(for: code)
    }
}
