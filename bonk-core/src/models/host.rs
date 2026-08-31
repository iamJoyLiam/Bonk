use super::AuthType;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Mirrors BonkMac HostItem but as pure DTO (no @Model, no SwiftData)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostItemDto {
    pub id: Uuid,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_type: AuthType,
    pub group_id: Option<Uuid>,
    pub credential_id: Option<Uuid>,
    pub jump_host_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub last_connected_at: Option<DateTime<Utc>>,
    pub sort_order: i32,
    pub is_favorite: bool,
    pub is_serial: bool,
    pub serial_baud_rate: Option<u32>,
    pub force_compatibility: bool,
}

impl HostItemDto {
    pub fn endpoint_key(&self) -> String {
        format!("{}:{}@{}:{}", self.username, self.id, self.host, self.port)
    }
}

/// SSH connection config built from HostItemDto + secrets from Keychain
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshConnectionConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_type: AuthType,
    /// Resolved secret (password or private key PEM) - never serialize to disk
    #[serde(skip)]
    pub secret: Option<String>,
    /// Jump host chain
    pub jump_hosts: Vec<JumpHostDto>,
    /// Timeout secs
    pub timeout_secs: u64,
    /// Keepalive interval secs (0 = disabled)
    pub keepalive_secs: u64,
}

impl Default for SshConnectionConfig {
    fn default() -> Self {
        Self {
            host: String::new(),
            port: 22,
            username: String::new(),
            auth_type: AuthType::Password,
            secret: None,
            jump_hosts: vec![],
            timeout_secs: 15,
            keepalive_secs: 30,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JumpHostDto {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_type: AuthType,
    #[serde(skip)]
    pub secret: Option<String>,
}

/// Backend preference - mirrors SSHBackendProfile but as DTO
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackendProfileDto {
    pub host: String,
    pub port: u16,
    pub backend: String, // "native" | "compat"
    pub reason: String,
    pub detected_at: DateTime<Utc>,
}
