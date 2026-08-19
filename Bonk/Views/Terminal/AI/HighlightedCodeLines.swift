import SwiftUI

/// Monospaced code body with line numbers and shell syntax highlighting.
/// Shared by read-only and interactive code blocks.
struct HighlightedCodeLines: View {
    let code: String
    var fontSize: CGFloat = 12

    private var lines: [String] {
        code.components(separatedBy: "\n")
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: fontSize - 1, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 30, alignment: .trailing)
                            .selectionDisabled(true)
                        Text(ShellSyntaxHighlighter.highlight(line, fontSize: fontSize))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}