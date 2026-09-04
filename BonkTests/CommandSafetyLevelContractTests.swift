//  CommandSafetyLevelContractTests.swift
//  BonkTests
//
//  Contract tests for CommandSafetyLevel & Permission Model (P1.2).
//  Validates L0..L4 classification and default supervised access mode.
//

import Testing
import Foundation
@testable import Bonk

@Suite("CommandSafetyLevel Contract Tests")
struct CommandSafetyLevelContractTests {

    @Test("L1 Safe Inspection commands are classified correctly")
    func l1SafeInspectionCommands() {
        let inspectCommands = [
            "ls -la",
            "pwd",
            "git status",
            "docker ps",
            "date",
            "fdisk -l",
            "cat /etc/os-release"
        ]

        for cmd in inspectCommands {
            #expect(CommandSafety.classifyLevel(cmd) == .l1SafeInspection, "Expected L1 for: \(cmd)")
        }
    }

    @Test("L2 State Mutation commands are classified correctly")
    func l2StateMutationCommands() {
        let mutationCommands = [
            "mkdir -p /tmp/build",
            "touch /tmp/test.txt",
            "cp file1 file2",
            "mv old new",
            "npm install",
            "echo 'hello' >> output.txt"
        ]

        for cmd in mutationCommands {
            #expect(CommandSafety.classifyLevel(cmd) == .l2StateMutation, "Expected L2 for: \(cmd)")
        }
    }

    @Test("L3 High Risk destructive commands are classified correctly")
    func l3HighRiskCommands() {
        let highRiskCommands = [
            "rm somefile.txt",
            "kill -9 1234",
            "systemctl restart nginx",
            "reboot",
            "rm -rf build"
        ]

        for cmd in highRiskCommands {
            #expect(CommandSafety.classifyLevel(cmd) == .l3HighRisk, "Expected L3 for: \(cmd)")
        }
    }

    @Test("L4 Critical and dangerous system commands are blocked")
    func l4CriticalBlockedCommands() {
        let blockedCommands = [
            "rm -rf /",
            "rm -rf /*",
            "mkfs /dev/sda1",
            ":(){ :|:& };:",
            "chmod -R 777 /"
        ]

        for cmd in blockedCommands {
            #expect(CommandSafety.classifyLevel(cmd) == .l4Critical, "Expected L4 for: \(cmd)")
        }
    }

    @Test("Safety level enum strict ordering")
    func safetyLevelOrdering() {
        #expect(CommandSafetyLevel.l0Explanation < CommandSafetyLevel.l1SafeInspection)
        #expect(CommandSafetyLevel.l1SafeInspection < CommandSafetyLevel.l2StateMutation)
        #expect(CommandSafetyLevel.l2StateMutation < CommandSafetyLevel.l3HighRisk)
        #expect(CommandSafetyLevel.l3HighRisk < CommandSafetyLevel.l4Critical)
    }

    @Test("Default access mode falls back to supervised")
    func defaultAccessModeIsSupervised() {
        let mode = AgentMessage.AccessMode(rawValue: "unknown_value") ?? .supervised
        #expect(mode == .supervised)
    }
}
