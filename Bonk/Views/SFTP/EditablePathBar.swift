import SwiftUI

/// Single-TextField editable path bar — avoids Text↔TextField view replacement
/// layout thrash (AGENTS.md: keep intrinsic size / baseline stable).
struct EditablePathBar: View {
    @Binding var path: String
    @Binding var isEditing: Bool
    var onCommit: (String) -> Void
    var onGoUp: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var editingText: String = ""

    var body: some View {
        HStack(spacing: AppStyle.spacingS) {
            if let onGoUp {
                Button(action: onGoUp) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: AppStyle.fontSmall, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(path == "/" || isEditing)
            }

            TextField("", text: $editingText, prompt: Text(path).font(.system(size: AppStyle.fontSmall).monospaced()))
                .font(.system(size: AppStyle.fontSmall).monospaced())
                .textFieldStyle(.plain)
                .focused($isFocused)
                .disabled(!isEditing)
                .onChange(of: path) { _, n in if !isEditing { editingText = n } }
                .onAppear { editingText = path }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { guard !isEditing else { return }; editingText = path; isEditing = true; isFocused = true }
                .onSubmit { commit() }
                .onExitCommand { isEditing = false }

            Button {
                if isEditing { commit() } else { editingText = path; isEditing = true; isFocused = true }
            } label: {
                Image(systemName: isEditing ? "arrow.right.circle.fill" : "arrow.right.circle")
                    .font(.system(size: AppStyle.fontMedium))
                    .foregroundStyle(isEditing ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .help(isEditing ? "Go" : "Edit")
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingS)
        .background(.quaternary.opacity(AppStyle.opacityOverlay))
        .onChange(of: isEditing) { _, editing in
            if editing { editingText = path; isFocused = true } else { isFocused = false }
        }
    }

    private func commit() {
        let t = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { isEditing = false; return }
        onCommit(t)
        // Caller decides whether to stay editing (error) or exit; default exit
        // is handled by caller via isEditing binding. For immediate clear we
        // sync editingText to path.
        editingText = path
    }
}
