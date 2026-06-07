import SwiftUI

extension AIChatSidebarView {

    var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(i18n.t(.terminalAssistant))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    func bubble(_ msg: AIMessageRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.role == .assistant { avatar("sparkles") }
            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
                Text.markdown(msg.content).font(.system(size: 13)).textSelection(.enabled)
            }
            .padding(10)
            .background(msg.role == .user ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlColor))
            .clipShape(.rect(cornerRadius: 10))
            if msg.role == .user { avatar("person.fill") }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
    }

    func streamingBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            avatar("sparkles")
            Text(text).font(.system(size: 13))
                .padding(10)
                .background(Color(nsColor: .controlColor))
                .clipShape(.rect(cornerRadius: 10))
        }
    }

    func avatar(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background(Color(nsColor: .controlColor))
            .clipShape(Circle())
    }
}
