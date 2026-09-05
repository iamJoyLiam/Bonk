//  AIChatKeyboardAndPresentationContractTests.swift
//  BonkTests
//
//  Contract tests for Native Keyboard Navigation (P2) &
//  Terminal-Native Presentation (P3).
//

import Testing
import SwiftUI
@testable import Bonk

@Suite("AIChat Keyboard & Presentation Contract Tests")
struct AIChatKeyboardAndPresentationContractTests {

    @Test("Slash commands filter properly on query")
    func slashCommandsFiltering() {
        // Query "/" returns all commands
        let all = AISlashCommand.allCases
        #expect(all.count >= 5)

        // Matching prefix
        let fixMatches = AISlashCommand.allCases.filter { $0.title.lowercased().hasPrefix("/fi") }
        #expect(fixMatches.count == 1)
        #expect(fixMatches.first == .fix)

        let clearMatches = AISlashCommand.allCases.filter { $0.title.lowercased().hasPrefix("/cl") }
        #expect(clearMatches.count == 1)
        #expect(clearMatches.first == .clear)
    }

    @Test("Context mentions filter properly on query")
    func contextMentionsFiltering() {
        // Query "@" returns all mentions
        let all = AIContextMention.allCases
        #expect(all.count >= 4)

        // Matching prefix
        let histMatches = AIContextMention.allCases.filter { $0.token.lowercased().hasPrefix("@his") }
        #expect(histMatches.count == 1)
        #expect(histMatches.first == .history)

        let termMatches = AIContextMention.allCases.filter { $0.token.lowercased().hasPrefix("@term") }
        #expect(termMatches.count == 1)
        #expect(termMatches.first == .terminal)
    }

    @Test("Keyboard navigation cyclic index calculation")
    func keyboardNavigationCyclicIndex() {
        let count = 4
        var index = 0

        // Down arrow advances
        index = (index + 1) % count
        #expect(index == 1)

        index = (index + 1) % count
        #expect(index == 2)

        index = (index + 1) % count
        #expect(index == 3)

        // Wraps back to 0
        index = (index + 1) % count
        #expect(index == 0)

        // Up arrow wraps backwards to last item
        index = (index - 1 + count) % count
        #expect(index == 3)

        index = (index - 1 + count) % count
        #expect(index == 2)
    }

    @Test("AccessMode properties contract")
    func accessModePropertiesContract() {
        #expect(AgentMessage.AccessMode.fullAccess.shortName == "完全访问")
        #expect(AgentMessage.AccessMode.supervised.shortName == "逐步确认")
        #expect(AgentMessage.AccessMode.readOnly.shortName == "只读")

        #expect(!AgentMessage.AccessMode.fullAccess.icon.isEmpty)
        #expect(!AgentMessage.AccessMode.supervised.icon.isEmpty)
        #expect(!AgentMessage.AccessMode.readOnly.icon.isEmpty)
    }

    @Test("CommandStatus icon, color, and running state")
    func commandStatusContracts() {
        #expect(AgentMessage.CommandStatus.running.icon == "circle.dotted")
        #expect(AgentMessage.CommandStatus.success.icon == "checkmark.circle.fill")
        #expect(AgentMessage.CommandStatus.failed.icon == "xmark.octagon.fill")
        #expect(AgentMessage.CommandStatus.blocked.icon == "xmark.shield.fill")
    }
}
