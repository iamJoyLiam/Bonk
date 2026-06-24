import SwiftUI

/// Interactive code block with SSH execution capability.
/// Shows code with a RUN button, executes via SSH, displays output in an embedded console.
struct InteractiveCodeBlock: View {
    @Environment(I18n.self) var i18n
    let code: String
    let language: String?
    let sshService: SSHNetworkService?

    @State private var executionStatus: ExecutionStatus = .idle
    @State private var consoleOutput = ""
    @State private var executionTask: Task<Void, Never>?
    @State private var copied = false

    enum ExecutionStatus: Equatable {
        case idle
        case running
        case finished(exitCode: Int32)
        case error(String)
    }

    private var isShellLanguage: Bool {
        guard let lang = language?.lowercased() else { return true }
        return ["bash", "sh", "zsh", "shell"].contains(lang)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)

                if let lang = language {
                    Text(lang.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isShellLanguage, sshService != nil {
                    Button { toggleExecution() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: executionStatus == .running ? "stop.fill" : "play.fill")
                            Text(executionStatus == .running ? "STOP" : "RUN")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(executionStatus == .running ? .red : .green)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in try? await Task.sleep(for: .seconds(2));  copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlColor).opacity(0.5))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))

            // Console output (shown when running or has output)
            if executionStatus != .idle || !consoleOutput.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()

                    HStack {
                        Text(i18n.t(.output).uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if case let .finished(exitCode) = executionStatus {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(exitCode == 0 ? Color.green : Color.red)
                                    .frame(width: 6, height: 6)
                                Text(String(format: i18n.t(.exitCode), exitCode))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(exitCode == 0 ? .green : .red)
                            }
                        }
                        if case let .error(msg) = executionStatus {
                            Text(msg)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                    ScrollView(.vertical, showsIndicators: true) {
                        Text(consoleOutput.isEmpty ? i18n.t(.waitingForOutput) : consoleOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(consoleOutput.isEmpty ? Color.secondary : Color.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 60, maxHeight: 160)
                    .background(Color.black.opacity(0.9))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .onDisappear {
            executionTask?.cancel()
        }
    }

    // MARK: - Execution

    private func toggleExecution() {
        if executionStatus == .running {
            stopExecution()
        } else {
            startExecution()
        }
    }

    private func startExecution() {
        guard let sshService else { return }
        executionStatus = .running
        consoleOutput = ""

        executionTask = Task {
            do {
                let output = try await sshService.executeCommand(code)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    consoleOutput = output
                    executionStatus = .finished(exitCode: 0)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    consoleOutput = error.localizedDescription
                    executionStatus = .error(i18n.t(.failed))
                }
            }
        }
    }

    private func stopExecution() {
        executionTask?.cancel()
        executionTask = nil
        executionStatus = .finished(exitCode: -1)
        consoleOutput += "\n[Cancelled]"
    }
}
