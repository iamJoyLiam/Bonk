//
//  LocalFileRow.swift
//  Bonk
//
//  Local file entry model and row view for SFTP window.
//

import SwiftUI

// MARK: - Local File Entry

struct LocalFileEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modifiedAt: Date?
}

// MARK: - Local File Row (matches SFTPFileRow layout)

struct LocalFileRow: View {
    @Environment(I18n.self) var i18n
    let file: LocalFileEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: AppStyle.fontMedium))
                .foregroundStyle(iconColor)
                .frame(width: AppStyle.iconDisplay)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: AppStyle.fontBody))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if file.isDirectory {
                        Text(i18n.t(.folder))
                            .font(.system(size: AppStyle.fontSmallest))
                            .foregroundStyle(.tertiary)
                    } else {
                        let ext = (file.name as NSString).pathExtension
                        if !ext.isEmpty {
                            Text(ext.uppercased())
                                .font(.system(size: AppStyle.fontSmallest).monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Text(formatSize(file.size))
                            .font(.system(size: AppStyle.fontSmallest))
                            .foregroundStyle(.tertiary)
                    }
                    if let date = file.modifiedAt {
                        Text(Self.dateFormatter.string(from: date))
                            .font(.system(size: AppStyle.fontSmallest))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, AppStyle.spacingXXS)
    }

    private var icon: String {
        if file.isDirectory { return "folder.fill" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh", "py", "rb", "pl": return "terminal"
        case "yml", "yaml", "json", "xml", "toml": return "doc.text"
        case "txt", "log", "md": return "doc.plaintext"
        case "jpg", "jpeg", "png", "gif", "svg": return "photo"
        case "zip", "tar", "gz", "bz2", "xz": return "archivebox"
        case "conf", "cfg", "ini", "env": return "gearshape"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        if file.isDirectory { return .blue }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh", "py", "rb": return .green
        case "yml", "yaml", "json", "xml": return .orange
        case "log", "txt": return .gray
        case "jpg", "jpeg", "png", "gif": return .purple
        default: return .secondary
        }
    }

    private func formatSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1024 / 1024) }
        return String(format: "%.1f GB", Double(bytes) / 1024 / 1024 / 1024)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
