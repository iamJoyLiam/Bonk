import SwiftUI

extension Text {
    /// Render text with basic markdown support. Falls back to plain text on failure.
    static func markdown(_ content: String) -> Text {
        if let attr = try? AttributedString(markdown: content) { return Text(attr) }
        return Text(content)
    }
}
