//! Broadcast - send keystrokes to multiple sessions at once
//! Mirrors BonkMac BroadcastMode. Pure logic, no OS deps.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use crate::error::CoreResult;

/// Broadcast group
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BroadcastGroup {
    pub id: String,
    pub session_ids: Vec<String>,
    pub enabled: bool,
}

impl Default for BroadcastGroup {
    fn default() -> Self { Self { id: uuid::Uuid::new_v4().to_string(), session_ids: vec![], enabled: false } }
}

#[async_trait]
pub trait BroadcastService: Send + Sync {
    async fn start(&self, session_ids: Vec<String>) -> CoreResult<BroadcastGroup>;
    async fn stop(&self, group_id: &str) -> CoreResult<()>;
    async fn send(&self, group_id: &str, data: &[u8]) -> CoreResult<()>;
    async fn list(&self) -> CoreResult<Vec<BroadcastGroup>>;
}

pub struct InMemoryBroadcastService {
    inner: std::sync::Arc<tokio::sync::RwLock<Vec<BroadcastGroup>>>,
}

impl InMemoryBroadcastService {
    pub fn new() -> Self { Self { inner: std::sync::Arc::new(tokio::sync::RwLock::new(vec![])) } }
}

impl Default for InMemoryBroadcastService { fn default() -> Self { Self::new() } }

#[async_trait]
impl BroadcastService for InMemoryBroadcastService {
    async fn start(&self, session_ids: Vec<String>) -> CoreResult<BroadcastGroup> {
        let g = BroadcastGroup { id: uuid::Uuid::new_v4().to_string(), session_ids, enabled: true };
        self.inner.write().await.push(g.clone());
        Ok(g)
    }
    async fn stop(&self, group_id: &str) -> CoreResult<()> {
        self.inner.write().await.retain(|g| g.id != group_id);
        Ok(())
    }
    async fn send(&self, _group_id: &str, _data: &[u8]) -> CoreResult<()> {
        // mock: in real impl, iterate sessions and call pty.write
        Ok(())
    }
    async fn list(&self) -> CoreResult<Vec<BroadcastGroup>> {
        Ok(self.inner.read().await.clone())
    }
}
