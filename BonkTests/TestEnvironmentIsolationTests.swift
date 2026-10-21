//
//  TestEnvironmentIsolationTests.swift
//  BonkTests
//
//  The Bonk app hosts the test bundle, so every test run boots the real
//  application. Before this guard existed, that meant: the main window
//  opened, the Quake panel came up over the developer's work, a system-wide
//  hotkey was registered, the app took focus, and the launch-time
//  `pkill` of orphaned SSH muxes took down the developer's live sessions.
//
//  A test run that takes over the machine is not a test run the developer
//  can work alongside, so the isolation is asserted here rather than left
//  to good intentions.
//

import Foundation
import Testing
@testable import Bonk

@Suite("Test Environment Isolation Tests")
struct TestEnvironmentIsolationTests {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BonkTests
            .deletingLastPathComponent() // repo root
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("This process is detected as a test host")
    func testHostIsDetected() {
        // If the detection ever stops working, every test run goes back to
        // opening windows on the developer's screen — and this test is the
        // first thing that would notice.
        #expect(TestEnvironment.isRunningTests,
                "the app must be able to tell that it is hosting tests")
    }

    @Test("The app delegate does not open a window under a test host")
    func appDelegateSuppressesItsWindow() throws {
        let delegate = try source("Bonk/State/BonkAppDelegate.swift")
        #expect(delegate.contains("TestEnvironment.isRunningTests"),
                "the app delegate must skip window creation when hosting tests")
    }

    @Test("The Quake terminal is not set up under a test host")
    func quakeTerminalIsNotSetUp() throws {
        let content = try source("Bonk/ContentView.swift")
        #expect(content.contains("TestEnvironment.isRunningTests"),
                "the Quake panel must not be created when hosting tests")
    }

    @Test("A test host does not kill live SSH sessions")
    func testHostDoesNotKillLiveSessions() throws {
        let backend = try source("Bonk/Services/SSH/OpenSSHBackend+ControlMaster.swift")
        #expect(backend.contains("TestEnvironment.isRunningTests"),
                "the launch-time mux cleanup must not run in a test host: it would kill the developer's live SSH sessions")
    }
}
