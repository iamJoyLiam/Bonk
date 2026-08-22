import SwiftUI

extension AIChatSidebarView {
    var historyPopover: some View {
        VStack(spacing: 0) {
            if conversations.isEmpty {
                Text(i18n.t(.aiNoHistory))
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(AppStyle.spacingXL)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(conversations) { conversation in
                            HStack(spacing: 8) {
                                Button {
                                    currentConversation = conversation
                                    conversationStore.lastConversationID = conversation.id
                                    showHistory = false
                                } label: {
                                    HStack {
                                        Text(conversation.title)
                                            .font(.system(size: AppStyle.fontBody))
                                            .lineLimit(1)
                                        Spacer()
                                        if currentConversation?.id == conversation.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: AppStyle.fontCaption))
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
                                        .font(.system(size: AppStyle.fontSmallest, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, AppStyle.spacingL).padding(.vertical, AppStyle.spacingS)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .frame(width: AppStyle.size220)
        .alert(i18n.t(.aiDeleteConversation), isPresented: Binding(
            get: { pendingDeleteConversation != nil },
            set: { if !$0 { pendingDeleteConversation = nil } }
        )) {
            Button(i18n.t(.delete), role: .destructive) {
                if let id = pendingDeleteConversation,
                   let conv = conversations.first(where: { $0.id == id })
                {
                    conversationStore.delete(conv, context: modelContext)
                    if currentConversation?.id == id { currentConversation = nil }
                    if conversationStore.lastConversationID == id {
                        conversationStore.lastConversationID = nil
                    }
                }
                pendingDeleteConversation = nil
            }
            Button(i18n.t(.cancel), role: .cancel) { pendingDeleteConversation = nil }
        }
    }
}
