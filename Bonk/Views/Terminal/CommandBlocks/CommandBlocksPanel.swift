//
//  CommandBlocksPanel.swift
//  Bonk – Warp-style command grouping (M7 #14)
//  Each shell command (OSC 133) is a block: copy cmd/output, search, jump.
//

import AppKit
import SwiftTerm
import SwiftUI

struct CommandBlocksPanel: View {
    @Environment(I18n.self) var i18n
    let paneID: UUID
    let ptySession: PTYSession?
    @Binding var isPresented: Bool

    @State private var searchText = ""
    @State private var blocks: [CommandBlock] = []
    @State private var expanded: Set<UUID> = []
    @State private var copyTip: String?

    var filtered: [CommandBlock] {
        if searchText.isEmpty { return blocks.reversed() }
        let query = searchText.lowercased()
        return blocks.reversed().filter { $0.command.lowercased().contains(query) || $0.output.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if blocks.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                Text(i18n.t(.noResults))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .commandBlockDidAdd)) { note in
            if let block = note.userInfo?["block"] as? CommandBlock {
                reload()
                withAnimation { _ = expanded.insert(block.id) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .commandBlocksDidClear)) { _ in reload() }
        .overlay(alignment: .top) { if let tip = copyTip { tipView(tip) } }
    }

    private func reload() {
        blocks = ptySession?.allCommandBlocks() ?? []
        if blocks.count > 3 {
            // Auto-expand latest 3
            let latest = blocks.suffix(3).map(\.id)
            expanded.formUnion(latest)
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 8) {
            Label(i18n.t(.blocks), systemImage: "rectangle.grid.1x2")
                .font(.headline)
            Spacer()
            if !blocks.isEmpty {
                Text("\(filtered.count)/\(blocks.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    ptySession?.clearCommandBlocks()
                    NotificationCenter.default.post(name: .commandBlocksDidClear, object: nil)
                    reload()
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless).help(i18n.t(.delete))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if !blocks.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField(i18n.t(.searchCommandOrOutput), text: $searchText)
                        .textFieldStyle(.plain).font(.callout)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 10).padding(.bottom, 8)
                .offset(y: 44)
            }
        }
        .padding(.bottom, blocks.isEmpty ? 0 : 28)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
            Text(i18n.t(.noCommands))
                .font(.callout.weight(.medium))
            Text(i18n.t(.shellIntegrationHint))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
            if let cmd = sampleInstallCommand {
                Button { copy(cmd) } label: { Label(i18n.t(.copySnippet), systemImage: "doc.on.doc") }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var sampleInstallCommand: String? {
        // Minimal zsh snippet
        "precmd(){ print -Pn \"\\e]133;A\\e\\\\\" }\npreexec(){ print -Pn \"\\e]133;C\\e\\\\\" }\nprecmd(){ local s=$?; print -Pn \"\\e]133;D;$s\\e\\\\\"; print -Pn \"\\e]133;A\\e\\\\\" }"
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filtered) { block in
                    blockRow(block)
                }
            }
            .padding(10)
        }
    }

    private func blockRow(_ block: CommandBlock) -> some View {
        let isExpanded = expanded.contains(block.id)
        return VStack(alignment: .leading, spacing: 0) {
            // Header — command line + actions
            HStack(spacing: 8) {
                statusDot(exitCode: block.exitCode)
                Text(block.command.isEmpty ? "(empty)" : block.command)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(isExpanded ? nil : 2)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                if !block.durationLabel.isEmpty {
                    Text(block.durationLabel).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                }
                if let code = block.exitCode {
                    Text("\(code)").font(.caption2.monospaced())
                        .foregroundStyle(code == 0 ? .green : .red)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background((code == 0 ? SwiftUI.Color.green : SwiftUI.Color.red).opacity(0.12), in: Capsule())
                }
                Menu {
                    Button(i18n.t(.copyCommand)) { copy(block.command) }
                    Button(i18n.t(.copyOutput)) { copy(block.output) }
                    Button(i18n.t(.copyBoth)) { copy("$ \(block.command)\n\(block.output)") }
                    Divider()
                    Button(i18n.t(.searchInTerminal)) { searchInTerminal(block.command) }
                    Button(i18n.t(.rerunCommand)) { rerun(block.command) }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.automatic)
                .frame(width: 20, height: 20)
                Button { withAnimation(.easeInOut(duration: 0.15)) { toggle(block.id) } } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { toggle(block.id) } }

            if isExpanded {
                Divider()
                // Output
                VStack(alignment: .leading, spacing: 6) {
                    if block.output.isEmpty {
                        Text("(no output)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(block.output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 8) {
                        Button { copy(block.output) } label: { Label(i18n.t(.copyOutput), systemImage: "doc.on.doc") }
                            .controlSize(.small)
                        Button { searchInTerminal(block.output.prefix(80).description) } label: { Label(i18n.t(.find), systemImage: "magnifyingglass") }
                            .controlSize(.small)
                        Spacer()
                        Text(block.startTime.formatted(date: .omitted, time: .standard))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(SwiftUI.Color(nsColor: .textBackgroundColor))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SwiftUI.Color(nsColor: .separatorColor)))
    }

    private func statusDot(exitCode: Int?) -> some View {
        let color: SwiftUI.Color = exitCode == nil ? .secondary : (exitCode == 0 ? .green : .red)
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copyTip = i18n.t(.copied) }
        Task { @MainActor in try? await Task.sleep(for: .seconds(1.2)); withAnimation { copyTip = nil } }
    }

    private func tipView(_ text: String) -> some View {
        Text(text).font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func searchInTerminal(_ term: String) {
        let pid = paneID
        if let view = TerminalViewCache.shared.retrieve(pid)?.view {
            _ = view.findNext(term)
        }
    }

    private func rerun(_ command: String) {
        guard let pty = ptySession else { return }
        let bytes = ArraySlice((command + "\n").utf8)
        Task { try? await pty.sendInput(bytes) }
    }
}
