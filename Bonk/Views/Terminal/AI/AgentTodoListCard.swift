//
//  AgentTodoListCard.swift
//  Bonk
//
//  The task list the model writes for itself.
//

import SwiftUI

/// The model's task list.
///
/// Shown above the transcript: the plan the agent is working through, in
/// the model's own words. The app does not interpret it — it is the
/// model's list, and the user reads it the way the model does.
struct AgentTodoListCard: View {
    let todos: [AgentTodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.spacingXS) {
            HStack(spacing: AppStyle.spacingXS) {
                Image(systemName: "checklist")
                    .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("Task list")
                    .font(.system(size: AppStyle.fontSmall, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            ForEach(Array(todos.enumerated()), id: \.offset) { _, item in
                row(item)
            }
        }
        .padding(AppStyle.spacingM)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func row(_ item: AgentTodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.spacingXS) {
            Image(systemName: icon(for: item.status))
                .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                .foregroundStyle(color(for: item.status))
            // While a task is in progress the user reads what is happening,
            // not what was planned.
            Text(item.status == .inProgress ? (item.activeForm ?? item.content) : item.content)
                .font(.system(size: AppStyle.fontSmall))
                .foregroundStyle(item.status == .completed ? .secondary : .primary)
                .strikethrough(item.status == .completed, color: .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func icon(for status: AgentTodoItem.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted"
        case .pending: "circle"
        }
    }

    private func color(for status: AgentTodoItem.Status) -> Color {
        switch status {
        case .completed: .green
        case .inProgress: .accentColor
        case .pending: .secondary
        }
    }
}
