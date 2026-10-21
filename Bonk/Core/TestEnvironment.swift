//
//  TestEnvironment.swift
//  Bonk
//
//  Detects that this process is the host for a test bundle.
//
//  The Bonk app hosts `BonkTests`, so every test run boots the real
//  application: the main window opens, the Quake panel comes up over
//  whatever the developer was doing, a global hotkey is registered with the
//  system, and the app takes focus. That hijacks the machine mid-work.
//
//  Tests need the app's services, its model container and its session
//  manager — not its windows. Suppressing the windows changes nothing the
//  tests assert on, and it keeps the developer's screen theirs.
//

import Foundation

enum TestEnvironment {

    /// True when this process is running a test bundle.
    ///
    /// The check is behind `#if DEBUG` so a shipped build can never take
    /// this path, whatever the environment happens to carry.
    ///
    /// Xcode marks a test host with `XCTestConfigurationFilePath` and
    /// `XCTestBundlePath`; `XCTestCase` being loadable is the fallback for
    /// runners that set neither.
    static var isRunningTests: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
        #else
        return false
        #endif
    }
}
