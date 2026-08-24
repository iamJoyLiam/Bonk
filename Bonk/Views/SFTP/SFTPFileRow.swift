//
//  SFTPFileRow.swift
//  Bonk
//

import SwiftUI

/// A single file/directory row in the SFTP browser.
struct SFTPFileRow: View {
    let entry: SFTPFileEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: AppStyle.fontMedium))
                .foregroundStyle(iconColor)
                .frame(width: AppStyle.iconDisplay)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: AppStyle.fontBody))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(entry.permissionsString)
                        .font(.system(size: AppStyle.fontSmallest).monospaced())
                        .foregroundStyle(.tertiary)

                    if !entry.isDirectory {
                        Text(entry.sizeFormatted)
                            .font(.system(size: AppStyle.fontSmallest))
                            .foregroundStyle(.tertiary)
                    }

                    if let date = entry.modifiedAt {
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
        if entry.isDirectory { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
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
        if entry.isDirectory { return .blue }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh", "py", "rb": return .green
        case "yml", "yaml", "json", "xml": return .orange
        case "log", "txt": return .gray
        case "jpg", "jpeg", "png", "gif": return .purple
        default: return .secondary
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
