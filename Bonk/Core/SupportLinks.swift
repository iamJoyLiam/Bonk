import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// Single source of truth for Bonk's external links (repo / website / support).
///
/// Client principle: expose only this single entry point, opened in the system browser.
/// The client embeds no payment SDK, stores no card info, processes no payments,
/// keeps no wallet private keys, never depends on payment services, and keeps
/// payment logic out of the Terminal / AI Workspace core paths.
enum SupportLinks {
    // MARK: - Help

    static let repository = "https://github.com/iamJoyLiam/Bonk"
    static let issues = "https://github.com/iamJoyLiam/Bonk/issues"
    static let newIssue = "https://github.com/iamJoyLiam/Bonk/issues/new"
    static let releases = "https://github.com/iamJoyLiam/Bonk/releases"
    static let website = "https://bonk-terminal.pages.dev/"

    // MARK: - Support (single entry)

    /// Unified support entry. All payment methods (Afdian / WeChat Pay & Alipay /
    /// Stripe / PayPal / Crypto) are presented on that page; the client talks to
    /// no payment channel directly.
    /// GitHub Sponsors is not enabled for now.
    static let supportPage = "https://bonk-terminal.pages.dev/support.html"

    // MARK: - Open

    static func open(_ string: String?) {
        guard let string, let url = URL(string: string) else { return }
        #if canImport(AppKit)
            NSWorkspace.shared.open(url)
        #endif
    }
}
