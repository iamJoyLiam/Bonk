import Foundation
import os.log

/// Centralized logger with categories for different subsystems.
enum Log {
    private static let subsystem = "com.bonk.app"

    static let ssh = Logger(subsystem: subsystem, category: "SSH")
    static let sftp = Logger(subsystem: subsystem, category: "SFTP")
    static let pty = Logger(subsystem: subsystem, category: "PTY")
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let session = Logger(subsystem: subsystem, category: "Session")
    static let general = Logger(subsystem: subsystem, category: "General")
    static let copilot = Logger(subsystem: subsystem, category: "Copilot")
    static let ai = Logger(subsystem: subsystem, category: "AI")
}
