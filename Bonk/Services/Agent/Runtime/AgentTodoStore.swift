//
//  AgentTodoStore.swift
//  Bonk
//
//  The task list the model keeps for itself.
//
//  The model writes the whole list each time it changes, so this is a
//  replacement rather than an edit. That is Claude Code's shape, and it is
//  the right one: the model never has to reason about a diff, and a list
//  that goes stale cannot half-apply.
//
//  Why the model needs one at all: `AgentState.progress` counts the steps
//  that ran, but the model never saw them. It knew what it had asked for
//  and what had come back, and had to infer where it was from that. A list
//  it writes itself is the state it can actually read.
//

import Foundation

/// One item in the model's task list.
struct AgentTodoItem: Equatable, Sendable {
    enum Status: String, Sendable, Equatable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed

        /// Parse a status the model wrote.
        ///
        /// Liberal in what it accepts: a model that writes "inprogress" or
        /// "complete" meant the same thing, and rejecting the whole list over
        /// a spelling would only make it write again.
        init(modelText: String) {
            switch modelText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "in_progress", "inprogress", "in-progress", "in progress":
                self = .inProgress
            case "completed", "complete", "done":
                self = .completed
            default:
                self = .pending
            }
        }
    }

    /// What the task is.
    let content: String
    /// Where it stands.
    let status: Status
    /// The task in present continuous form ("Checking disk usage"), for the
    /// line the user reads while it is in progress.
    let activeForm: String?

    init(content: String, status: Status, activeForm: String? = nil) {
        self.content = content
        self.status = status
        self.activeForm = activeForm
    }
}

/// The task list for one run.
actor AgentTodoStore {
    private(set) var items: [AgentTodoItem] = []

    /// Replace the list.
    func replace(with items: [AgentTodoItem]) {
        self.items = items
    }

    /// How many items are in each state.
    func counts() -> (completed: Int, inProgress: Int, pending: Int) {
        (
            items.filter { $0.status == .completed }.count,
            items.filter { $0.status == .inProgress }.count,
            items.filter { $0.status == .pending }.count
        )
    }
}
