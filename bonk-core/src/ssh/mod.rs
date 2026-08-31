//! SSH abstraction - upper layers depend only on traits, not russh/libssh
//!
//! This mirrors BonkMac's SSHSession / SSHPTYChannel / SFTPChannel protocols
//! but in Rust (Send + Sync for cross-thread use).

pub mod config;
pub mod session;
// P0 扩展模块（精简落地，后续可拆独立文件）
pub mod decision;
pub use decision::*;

pub use config::*;
pub use session::*;

use async_trait::async_trait;
use bytes::Bytes;

use crate::error::CoreResult;
use crate::models::{SftpFileEntry, TerminalSize};
use serde::{Deserialize, Serialize};

/// Unified SSH session - same role as BonkMac's `SSHSession` protocol
#[async_trait]
pub trait SshSession: Send + Sync {
    /// Open interactive PTY channel (what xterm.js / SwiftTerm consumes)
    async fn open_pty(&self, size: TerminalSize) -> CoreResult<Box<dyn PtyChannel>>;

    /// Execute single command (non-interactive)
    async fn execute(&self, command: &str) -> CoreResult<CommandResult>;

    /// Open SFTP channel
    async fn open_sftp(&self) -> CoreResult<Box<dyn SftpChannel>>;

    /// Close session
    async fn close(&self) -> CoreResult<()>;
}

/// PTY channel - mirrors `SSHPTYChannel`
#[async_trait]
pub trait PtyChannel: Send + Sync {
    /// Write data to remote PTY (user keystrokes)
    async fn write(&self, data: &[u8]) -> CoreResult<()>;

    /// Resize terminal
    async fn resize(&self, size: TerminalSize) -> CoreResult<()>;

    /// Subscribe to output stream (server -> client)
    async fn next_output(&self) -> Option<Bytes>;

    /// Close channel
    async fn close(&self) -> CoreResult<()>;
}

/// SFTP channel - mirrors `SFTPChannel`
#[async_trait]
pub trait SftpChannel: Send + Sync {
    async fn real_path(&self) -> CoreResult<String>;
    async fn list_dir(&self, path: &str) -> CoreResult<Vec<SftpFileEntry>>;
    async fn create_dir(&self, path: &str) -> CoreResult<()>;
    async fn remove(&self, path: &str, is_dir: bool) -> CoreResult<()>;
    async fn upload(&self, local: &str, remote: &str) -> CoreResult<()>;
    async fn download(&self, remote: &str, local: &str) -> CoreResult<()>;
    async fn exists(&self, path: &str) -> CoreResult<bool>;
    async fn close(&self) -> CoreResult<()>;
}

#[derive(Debug, Clone)]
pub struct CommandResult {
    pub output: String,
    pub exit_code: i32,
}

/// Factory - decides backend (native russh vs compat OpenSSH) like BonkMac's SSHNetworkService
pub struct SshConnector {
    pub config: SshConnectionConfig,
}

impl SshConnector {
    pub fn new(config: SshConnectionConfig) -> Self {
        Self { config }
    }

    /// Resolve decision without IO (pure) - mirrors SSHSessionCoordinator.resolve
    pub fn resolve_decision(&self) -> SshDecision {
        let cfg = &self.config;
        // jump -> compatibility policy (v1)
        if !cfg.jump_hosts.is_empty() {
            return SshDecision::Compatibility { reason: SshBackendReason::JumpHost };
        }
        if cfg.auth_type == crate::models::AuthType::Certificate {
            return SshDecision::Compatibility { reason: SshBackendReason::ForcedCompatibility };
        }
        if cfg.auth_type == crate::models::AuthType::SecureEnclave {
            return SshDecision::Native;
        }
        // forward service check deferred; here assume terminal
        SshDecision::NativeWithFallback
    }

    /// Connect and return boxed session (auto-select backend by host capability)
    pub async fn connect(&self) -> CoreResult<Box<dyn SshSession>> {
        let decision = self.resolve_decision();
        tracing::info!("SshConnector decision={:?} for {}:{} jumps={}", decision, self.config.host, self.config.port, self.config.jump_hosts.len());
        // If jump chain present, log each hop (real impl would chain russh direct-tcpip)
        if !self.config.jump_hosts.is_empty() {
            tracing::info!("jump chain: {} hops", self.config.jump_hosts.len());
            // For P0, jump is mocked as direct connect with annotation
            // Real: connect to jump[0], then channel_open_direct_tcpip iteratively
        }
        #[cfg(feature = "ssh-russh")]
        {
            match decision {
                SshDecision::Compatibility { .. } => {
                    // P0: still try russh, but mark fallback available
                    // Real P1: spawn OpenSSH subprocess or ssh2
                    let sess = session::RusshSession::connect(self.config.clone()).await?;
                    Ok(Box::new(sess))
                },
                _ => {
                    let sess = session::RusshSession::connect(self.config.clone()).await?;
                    Ok(Box::new(sess))
                }
            }
        }
        #[cfg(not(feature = "ssh-russh"))]
        {
            Err(crate::error::CoreError::Ssh("SSH feature not enabled".into()))
        }
    }
}

use crate::models::SshConnectionConfig;

// ---------------------------------------------------------------------------
// Re-export backend decision types for FFI/Tauri
// ---------------------------------------------------------------------------
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SshBackendType { Native, Compatibility }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SshBackendReason { Modern, KexMismatch, HostKeyMismatch, CipherMismatch, NoKbdInteractive, JumpHost, ForcedCompatibility }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SshDecision { Native, Compatibility { reason: SshBackendReason }, NativeWithFallback }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FailureClassification { Transport, ProtocolCompatibility, BackendCapability, Authentication, Configuration, Unknown }

pub fn classify_failure(msg: &str) -> FailureClassification {
    let m = msg.to_lowercase();
    if m.contains("kex") || m.contains("hostkey") || m.contains("cipher") || m.contains("mac") { FailureClassification::ProtocolCompatibility }
    else if m.contains("no supported authentication") || m.contains("keyboard") { FailureClassification::BackendCapability }
    else if m.contains("permission denied") || m.contains("authentication failed") { FailureClassification::Authentication }
    else if m.contains("timeout") || m.contains("refused") || m.contains("dns") { FailureClassification::Transport }
    else { FailureClassification::Unknown }
}
