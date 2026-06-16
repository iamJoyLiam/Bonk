//
//  BroadcastIndicator.swift
//  Bonk
//

import SwiftUI

/// Visual indicator showing broadcast mode status.
struct BroadcastIndicator: View {
    @Environment(I18n.self) var i18n
    @Bindable var manager: BroadcastManager

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 12))
                .foregroundStyle(manager.isEnabled ? .orange : .secondary)

            if manager.isEnabled {
                Text(String(format: i18n.t(.broadcastPanes), manager.targetPaneIDs.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)

                Button {
                    manager.toggle()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(manager.isEnabled ? Color.orange.opacity(0.1) : Color.clear)
        .clipShape(Capsule())
        .onTapGesture {
            manager.toggle()
        }
    }
}

/// Broadcast mode toggle button for the terminal toolbar.
struct BroadcastToggleButton: View {
    @Environment(I18n.self) var i18n
    @Bindable var manager: BroadcastManager

    var body: some View {
        Button {
            manager.toggle()
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 14))
                .foregroundStyle(manager.isEnabled ? .orange : .secondary)
        }
        .help(manager.isEnabled ? i18n.t(.disableBroadcast) : i18n.t(.enableBroadcast))
        .popover(isPresented: .constant(manager.isEnabled)) {
            VStack(alignment: .leading, spacing: 8) {
                Text(i18n.t(.broadcastInput))
                    .font(.headline)

                Text(i18n.t(.selectPanes))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(manager.allPaneIDs, id: \.self) { id in
                    HStack {
                        Image(systemName: manager.targetPaneIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(manager.targetPaneIDs.contains(id) ? .blue : .secondary)
                        Text("\(i18n.t(.pane)) \(id.uuidString.prefix(8))")
                            .font(.system(size: 12))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        manager.togglePane(id)
                    }
                }

                Divider()

                HStack {
                    Button(i18n.t(.selectAll)) { manager.selectAll() }
                    Button(i18n.t(.deselectAll)) { manager.deselectAll() }
                }
            }
            .padding()
            .frame(width: 220)
        }
    }
}
