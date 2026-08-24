//
//  ImportRowView.swift
//  Bonk – reusable row for SSH/Tabby unified import (fixes h/p/u + redundancy)
//

import SwiftUI

struct ImportRowView: View {
    @Environment(I18n.self) private var i18n

    let title: String
    let hostname: String
    let port: Int
    let username: String
    let isSelected: Bool
    let isDuplicate: Bool
    let badgeTitle: String
    let badgeColor: Color
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20)).foregroundStyle(isSelected ? .blue : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium)).lineLimit(1)
                    if isDuplicate {
                        Text(i18n.t(.duplicate)).font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                    }
                }
                HStack(spacing: 10) {
                    Label(hostname, systemImage: "globe").font(.caption).foregroundStyle(.secondary)
                    if port != SSHConstants.defaultPort {
                        Label("\(port)", systemImage: "number").font(.caption).foregroundStyle(.secondary)
                    }
                    Label(username, systemImage: "person").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(badgeTitle).font(.caption2.weight(.medium))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(badgeColor.opacity(0.12)).cornerRadius(4)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle()).onTapGesture(perform: onToggle)
        .opacity(isDuplicate && !isSelected ? 0.75 : 1)
    }
}
