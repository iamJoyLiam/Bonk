//! Import / Export - SessionImporter
//! Mirrors BonkMac Services/Import/* (TabbyImporter/SessionImporter)

use serde::{Deserialize, Serialize};
use crate::error::{CoreError, CoreResult};
use crate::models::HostItemDto;
use uuid::Uuid;
use chrono::Utc;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportResult {
    pub source: String, // "ssh-config" | "tabby" | "securecrt" | "xshell"
    pub count: usize,
    pub hosts: Vec<HostItemDto>,
    pub warnings: Vec<String>,
}

#[async_trait::async_trait]
pub trait SessionImporter: Send + Sync {
    fn name(&self) -> &str;
    async fn discover(&self, input: &str) -> CoreResult<ImportResult>;
}

/// SSH config importer - parses ~/.ssh/config Host blocks
pub struct SshConfigImporter;
#[async_trait::async_trait]
impl SessionImporter for SshConfigImporter {
    fn name(&self) -> &str { "ssh-config" }
    async fn discover(&self, input: &str) -> CoreResult<ImportResult> {
        let mut hosts = vec![];
        let mut warnings = vec![];
        let mut cur: Option<HostItemDto> = None;
        for line in input.lines() {
            let t = line.trim();
            if t.is_empty() || t.starts_with('#') { continue; }
            let lower = t.to_lowercase();
            if lower.starts_with("host ") && !lower.contains('*') && !lower.contains('?') {
                if let Some(h) = cur.take() { hosts.push(h); }
                let name = t[5..].trim().split_whitespace().next().unwrap_or("imported").to_string();
                cur = Some(HostItemDto { id: Uuid::new_v4(), name: name.clone(), host: name.clone(), port: 22, username: "root".into(), auth_type: crate::models::AuthType::Password, group_id: None, credential_id: None, jump_host_id: None, created_at: Utc::now(), last_connected_at: None, sort_order: 0, is_favorite: false, is_serial: false, serial_baud_rate: None, force_compatibility: false });
            } else if let Some(h) = cur.as_mut() {
                if lower.starts_with("hostname ") { h.host = t[9..].trim().to_string(); }
                else if lower.starts_with("port ") { h.port = t[5..].trim().parse().unwrap_or(22); }
                else if lower.starts_with("user ") { h.username = t[5..].trim().to_string(); }
            }
        }
        if let Some(h) = cur.take() { hosts.push(h); }
        if hosts.is_empty() { warnings.push("No Host entries found".into()); }
        Ok(ImportResult { source: self.name().into(), count: hosts.len(), hosts, warnings })
    }
}

/// Tabby importer - JSON
pub struct TabbyImporter;
#[async_trait::async_trait]
impl SessionImporter for TabbyImporter {
    fn name(&self) -> &str { "tabby" }
    async fn discover(&self, input: &str) -> CoreResult<ImportResult> {
        let v: serde_json::Value = serde_json::from_str(input).map_err(|e| CoreError::InvalidArgument(e.to_string()))?;
        let mut hosts = vec![];
        if let Some(arr) = v.as_array() {
            for item in arr {
                let name = item.get("name").and_then(|x| x.as_str()).unwrap_or("tabby-host");
                let host = item.get("host").and_then(|x| x.as_str()).unwrap_or(name);
                hosts.push(HostItemDto { id: Uuid::new_v4(), name: name.into(), host: host.into(), port: 22, username: "root".into(), auth_type: crate::models::AuthType::Password, group_id: None, credential_id: None, jump_host_id: None, created_at: Utc::now(), last_connected_at: None, sort_order: 0, is_favorite:false, is_serial:false, serial_baud_rate: None, force_compatibility:false });
            }
        }
        Ok(ImportResult { source: self.name().into(), count: hosts.len(), hosts, warnings: vec![] })
    }
}

/// Export helper - hosts to JSON
pub fn export_hosts_json(hosts: &[HostItemDto]) -> CoreResult<String> {
    serde_json::to_string_pretty(hosts).map_err(|e| CoreError::InvalidArgument(e.to_string()))
}
