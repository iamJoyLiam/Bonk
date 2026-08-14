import Foundation

/// Snapshot of terminal state attached to an AI request.
struct TerminalContext: Sendable {
    var currentDirectory: String?
    var shell: String?
    var recentCommands: [String] = []
    var terminalOutput: String?
    var selection: String?
}

extension TerminalContext {
    /// Build from the active terminal tab. Cheap read-only snapshot at request
    /// time, so it always reflects the current session state.
    @MainActor
    init(tab: TerminalTab?) {
        currentDirectory = tab?.currentDirectory
        shell = nil
        recentCommands = GlobalCommandHistory.shared.commands.suffix(10).map(\.command)
        terminalOutput = tab?.session?.ptySession?.recentOutput(maxLines: 40) ?? ""
    }
}
