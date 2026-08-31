//! bonk-core - Cross-platform core for Bonk
//! 
//! Architecture:
//! - `models` : Pure DTOs (no DB, no OS) - shared by all platforms
//! - `ssh`    : SSH session abstraction + russh implementation
//! - `sftp`   : SFTP channel abstraction
//! - `pty`    : PTY / terminal emulation abstraction
//! - `storage`: Repository trait + SQLite impl (replaces SwiftData)
//! - `keychain`: CredentialStore trait + OS impls
//! - `ai`     : AI provider abstraction (OpenAI/Claude/Ollama) - pure HTTP
//! - `ffi`    : C ABI for Swift (mac) / Tauri (Win) / any FFI consumer
//!
//! Mac keeps SwiftUI/AppKit, but business logic gradually moves here via FFI.

pub mod ai;
pub mod broadcast;
pub mod error;
pub mod ffi;
pub mod forward;
pub mod import;
pub mod keychain;
pub mod log;
pub mod models;
pub mod monitor;
pub mod pty;
pub mod recording;
pub mod serial;
pub mod sftp;
pub mod snippet;
pub mod ssh;
pub mod storage;
pub mod team;
pub mod workspace;
pub mod settings;

pub use error::{CoreError, CoreResult};
pub use models::*;

/// Core version - keep in sync with BonkMac MARKETING_VERSION
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Initialize core (tracing, etc). Call once at startup.
pub fn init() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .try_init();
    tracing::info!("bonk-core v{} initialized", CORE_VERSION);
}
