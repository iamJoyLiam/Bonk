//
//  MarkdownFrontmatter.swift
//  Bonk
//
//  The `key: value` block at the top of a markdown file.
//

import Foundation

/// The frontmatter of a markdown file: the `key: value` lines between the
/// `---` markers, and the text after them.
///
/// One implementation, because two kinds of file on the host need it — a
/// skill and a sub-agent — and a parser that exists twice is a parser that
/// will disagree with itself.
///
/// A deliberately small subset of YAML: the top-level `key: value` lines
/// between the `---` markers. A full YAML parser is not needed for a few
/// fields, and a small parser cannot be talked into constructing objects.
enum MarkdownFrontmatter {

    /// The `key: value` fields in a frontmatter block.
    ///
    /// Keys are lowercased, so `Name:` and `name:` are the same field.
    static func fields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines(of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            // A nested key (`  something: x`) is not a top-level field.
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            fields[key.lowercased()] = value
        }
        return fields
    }

    /// The lines of a file's frontmatter, without the `---` markers.
    static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        lines.removeFirst()
        var result: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            result.append(line)
        }
        return result
    }

    /// The text after a file's frontmatter.
    static func body(of text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        var index = 1
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                return lines[(index + 1)...].joined(separator: "\n")
            }
            index += 1
        }
        return ""
    }
}
