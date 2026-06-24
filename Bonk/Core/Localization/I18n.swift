import Foundation

#if os(macOS)
    import AppKit
#endif

// MARK: - Reactive localization engine

@Observable
final class I18n: @unchecked Sendable {
    // MARK: State

    private(set) var lang: String

    // MARK: Singleton (for non-SwiftUI contexts)

    static let shared = I18n()

    // MARK: Private state

    private var _savedChoice: String

    // MARK: Init

    init() {
        let allKeys = Self.loadStrings()
        _allStrings = allKeys
        availableLanguages = Array(allKeys.keys).sorted()

        let saved = UserDefaults.standard.string(forKey: "app_language") ?? "system"
        let resolved = Self.resolve(saved, availableKeys: Array(allKeys.keys))
        lang = resolved
        _savedChoice = saved

        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if _savedChoice == "system" {
                let newLang = Self.resolve("system", availableKeys: Array(_allStrings.keys))
                if lang != newLang {
                    lang = newLang
                }
            }
        }
    }

    // MARK: Set language

    func setLanguage(_ code: String) {
        _savedChoice = code
        UserDefaults.standard.set(code, forKey: "app_language")

        if code == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }

        lang = Self.resolve(code, availableKeys: Array(_allStrings.keys))
        #if os(macOS)
            showRestartAlert()
        #endif
    }

    #if os(macOS)
        private func showRestartAlert() {
            let alert = NSAlert()
            alert.messageText = t(.restartRequired)
            alert.informativeText = t(.restartMessage)
            alert.alertStyle = .informational
            alert.addButton(withTitle: t(.restartNow))
            alert.addButton(withTitle: t(.restartLater))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSApp.terminate(nil)
            }
        }
    #endif

    // MARK: Current saved choice

    var savedChoice: String {
        _savedChoice
    }

    // MARK: Translate

    func t(_ key: LKey) -> String {
        let currentLang = lang // @Observable is thread-safe for reads
        return _allStrings[currentLang]?[key.rawValue] ?? _allStrings["en"]?[key.rawValue]
            ?? key.rawValue
    }

    func tr(_ key: LKey, args: CVarArg...) -> String {
        let template = t(key)
        return withVaList(args) { NSString(format: template, arguments: $0) as String }
    }

    // MARK: Available languages

    private(set) var availableLanguages: [String]

    // MARK: Display name

    func displayName(for code: String) -> String {
        let currentLang = lang
        let locale = Locale(identifier: currentLang)
        return locale.localizedString(forLanguageCode: code)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
    }

    // MARK: Private

    private let _allStrings: [String: [String: String]]

    private static func resolve(_ choice: String, availableKeys: [String]) -> String {
        if choice == "system" || choice.isEmpty {
            return preferredLanguage(availableKeys: availableKeys)
        }
        return choice
    }

    /// Robust system language detection using Locale.preferredLanguages.
    /// Works directly with BCP 47 tags to avoid Locale normalization losing script info.
    private static func preferredLanguage(availableKeys: [String]) -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"

        // Try exact match first (e.g. "zh-Hans-CN")
        if availableKeys.contains(preferred) {
            return preferred
        }

        // Parse BCP 47 tag: "zh-Hans-CN" → parts = ["zh", "Hans", "CN"]
        let parts = preferred.split(separator: "-").map(String.init)
        guard let langCode = parts.first else { return "en" }

        // Try langCode-script (e.g. "zh-Hans")
        if parts.count >= 2 {
            let candidate = "\(langCode)-\(parts[1])"
            if availableKeys.contains(candidate) {
                return candidate
            }
        }

        // Try just langCode (e.g. "en")
        if availableKeys.contains(langCode) {
            return langCode
        }

        // Prefix match: any key starting with langCode
        if let match = availableKeys.first(where: { $0.hasPrefix(langCode) }) {
            return match
        }

        return "en"
    }

    // MARK: JSON loading

    private static func loadStrings() -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        let subdirs = ["Localizations", ""]
        for sub in subdirs {
            let dir: String
            if sub.isEmpty {
                guard let resourcePath = Bundle.main.resourcePath else { continue }
                dir = resourcePath
            } else {
                guard let url = Bundle.main.url(forResource: sub, withExtension: nil) else { continue }
                dir = url.path
            }
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".json") {
                let langCode = (file as NSString).deletingPathExtension
                guard result[langCode] == nil else { continue }
                let path = (dir as NSString).appendingPathComponent(file)
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let dict = try? JSONDecoder().decode([String: String].self, from: data)
                {
                    result[langCode] = dict
                }
            }
        }
        return result
    }
}
