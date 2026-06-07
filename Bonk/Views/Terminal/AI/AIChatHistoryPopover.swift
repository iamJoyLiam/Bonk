import SwiftUI

extension AIChatSidebarView {

    var historyPopover: some View {
        VStack(spacing: 0) {
            if conversations.isEmpty {
                Text(i18n.t(.aiNoHistory))
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(conversations) { conversation in
                            HStack(spacing: 8) {
                                Button {
                                    currentConversation = conversation
                                    showHistory = false
                                } label: {
                                    HStack {
                                        Text(conversation.title)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        Spacer()
                                        if currentConversation?.id == conversation.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    pendingDeleteConversation = conversation.id
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .frame(width: 220)
        .alert(i18n.t(.aiDeleteConversation), isPresented: Binding(
            get: { pendingDeleteConversation != nil },
            set: { if !$0 { pendingDeleteConversation = nil } }
        )) {
            Button(i18n.t(.delete), role: .destructive) {
                if let id = pendingDeleteConversation,
                   let conv = conversations.first(where: { $0.id == id }) {
                    conversationStore.delete(conv, context: modelContext)
                    if currentConversation?.id == id { currentConversation = nil }
                }
                pendingDeleteConversation = nil
            }
            Button(i18n.t(.cancel), role: .cancel) { pendingDeleteConversation = nil }
        }
    }
}
