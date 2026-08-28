import SwiftUI
import SwiftData

// MARK: - Row

struct PatternRowView: View {
    @Bindable var row: LogPatternRow
    var onEdit: () -> Void
    var onDelete: () -> Void
    @Environment(\.modelContext) private var ctx

    var body: some View {
        HStack(spacing: AppStyle.spacingM) {
            Circle().fill(LogColor.color(for: row.ansiCode)).frame(width: 12, height: 12).shadow(radius: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: AppStyle.fontBody, weight: .medium)).lineLimit(1)
                Text(row.pattern).font(.system(size: AppStyle.fontCaption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { row.enabled }, set: { new in
                row.enabled = new; try? ctx.save()
                Task { @MainActor in LogProfileStore.shared.refreshSnapshot() }
            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.plain).help("编辑")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).help("删除")
        }.padding(.vertical, 4)
    }
}
