//! Pure DTOs - no SwiftData, no OS dependency
//! These mirror BonkMac's HostItem/Credential but as plain structs.

pub mod host;

pub use host::*;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Auth method - mirrors BonkMac AuthType
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AuthType {
    Password,
    PrivateKey,
    Certificate,
    SecureEnclave, // mac only - on Win/Linux maps to privateKey
}

impl Default for AuthType {
    fn default() -> Self {
        Self::Password
    }
}

/// Terminal size
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSize {
    pub cols: u16,
    pub rows: u16,
}

impl Default for TerminalSize {
    fn default() -> Self {
        Self { cols: 120, rows: 40 }
    }
}

/// Connection state - mirrors SSHSessionState
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConnectionState {
    Idle,
    Connecting,
    Connected,
    Disconnected,
}

/// SFTP file entry - mirrors SFTPFileEntry
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SftpFileEntry {
    pub name: String,
    pub path: String,
    pub is_directory: bool,
    pub size: u64,
    pub modified: Option<chrono::DateTime<chrono::Utc>>,
    pub permissions: Option<String>,
}

/// Host group DTO
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostGroupDto {
    pub id: Uuid,
    pub name: String,
    pub sort_order: i32,
}

/// Credential DTO (never log the secret itself)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CredentialDto {
    pub id: Uuid,
    pub name: String,
    pub username: String,
}
