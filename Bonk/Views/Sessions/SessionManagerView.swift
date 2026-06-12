//
//  SessionManagerView.swift
//  Bonk
//

import SwiftData
import SwiftUI

/// Quick connect panel — shows saved sessions for one-click connection.
struct SessionManagerView: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedSession.sortOrder) private var sessions: [SavedSession]
    @Binding var isPresented: Bool
    let onConnect: (SavedSession) -> Void

    @State private var searchText = ""

    private var filteredSessions: [SavedSession] {
        if searchText.isEmpty { return sessions }
        let query = searchText.lowercased()
        return sessions.filter {
            $0.name.lowercased().contains(query)
                || $0.host.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.blue)
                Text(i18n.t(.sessions))
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField(i18n.t(.search), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Session list
            if filteredSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.noSessions))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.noSessionsHint))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    @ViewBuilder
    private func sessionRow(_ session: SavedSession) -> some View {
        Button {
            onConnect(session)
            session.recordConnection()
            isPresented = false
        } label: {
            HStack(spacing: 12) {
                // Favorite star
                Button {
                    session.isFavorite.toggle()
                } label: {
                    Image(systemName: session.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(session.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)

                // Status dot
                Circle()
                    .fill(session.lastConnectedAt != nil ? .green : .gray)
                    .frame(width: 8, height: 8)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.system(size: 13, weight: .medium))
                    Text("\(session.username)@\(session.host):\(session.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Connect count
                if session.connectCount > 0 {
                    Text("\(session.connectCount)x")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "bolt")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                session.isFavorite.toggle()
            } label: {
                Label(
                    session.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: session.isFavorite ? "star.slash" : "star"
                )
            }
            Divider()
            Button(role: .destructive) {
                modelContext.delete(session)
            } label: {
                Label(i18n.t(.delete), systemImage: "trash")
            }
        }
    }
}
