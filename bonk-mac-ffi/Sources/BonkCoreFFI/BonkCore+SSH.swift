import Foundation

// MARK: - Future FFI: SSH Session via Rust core
// This file is the integration point where BonkMac's SSHNetworkService
// will delegate to Rust. Keep BonkMac's `SSHSession` protocol unchanged,
// add a new `RustSSHAdapter: SSHSession` that forwards via FFI.
//
// Steps to wire (when Rust russh is ready):
//
// 1. In Rust, expose:
//      bonk_core_ssh_connect(config_json, on_connected: cb, on_data: cb, on_error: cb) -> session_id
//      bonk_core_ssh_write(session_id, bytes, len)
//      bonk_core_ssh_resize(session_id, cols, rows)
//      bonk_core_ssh_close(session_id)
//
// 2. In Swift, implement:
//
//    final class RustSSHSession: SSHSession {
//        let id: UInt64
//        func openPTY(...) throws -> PTYSession { /* create PTYSession that calls Rust write/resize */ }
//    }
//
// 3. Feature flag:
//      if UserDefaults.standard.bool(forKey: "useRustCore") { return RustSSHSession(...) }
//      else { return NativeSSHSession(...) } // existing Citadel path
//
// Until then, this file is a placeholder so the package compiles.

public final class RustCoreAvailability {
    public static var isAvailable: Bool {
        // After `cargo build --release`, check lib exists
        let fm = FileManager.default
        let libPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("bonk-core/target/release/libbonk_core.a")
        return fm.fileExists(atPath: libPath.path)
    }
}
