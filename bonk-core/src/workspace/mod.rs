//! Workspace / Layout
//! Mirrors BonkMac Models/Layout/* + WorkspaceManager
//! Layout is a binary tree of splits, persisted as JSON.

use serde::{Deserialize, Serialize};
use crate::error::CoreResult;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SplitDirection { Horizontal, Vertical }

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LayoutNodeDto {
    pub id: String,
    pub direction: Option<SplitDirection>,
    pub ratio: Option<f32>, // 0.0-1.0
    pub children: Vec<LayoutNodeDto>,
    pub tab_id: Option<String>, // leaf holds tab
}

impl LayoutNodeDto {
    pub fn leaf(tab_id: &str) -> Self {
        Self { id: Uuid::new_v4().to_string(), direction: None, ratio: None, children: vec![], tab_id: Some(tab_id.into()) }
    }
    pub fn split(dir: SplitDirection, ratio: f32, children: Vec<LayoutNodeDto>) -> Self {
        Self { id: Uuid::new_v4().to_string(), direction: Some(dir), ratio: Some(ratio), children, tab_id: None }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceDto {
    pub id: Uuid,
    pub name: String,
    pub root: LayoutNodeDto,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

#[async_trait::async_trait]
pub trait WorkspaceStore: Send + Sync {
    async fn list(&self) -> CoreResult<Vec<WorkspaceDto>>;
    async fn get(&self, id: Uuid) -> CoreResult<Option<WorkspaceDto>>;
    async fn upsert(&self, ws: WorkspaceDto) -> CoreResult<()>;
    async fn delete(&self, id: Uuid) -> CoreResult<()>;
}

pub struct InMemoryWorkspaceStore { inner: Arc<RwLock<Vec<WorkspaceDto>>> }

impl InMemoryWorkspaceStore { pub fn new() -> Self { Self { inner: Arc::new(RwLock::new(vec![])) } } }
impl Default for InMemoryWorkspaceStore { fn default() -> Self { Self::new() } }

#[async_trait::async_trait]
impl WorkspaceStore for InMemoryWorkspaceStore {
    async fn list(&self) -> CoreResult<Vec<WorkspaceDto>> { Ok(self.inner.read().await.clone()) }
    async fn get(&self, id: Uuid) -> CoreResult<Option<WorkspaceDto>> {
        Ok(self.inner.read().await.iter().find(|w| w.id==id).cloned())
    }
    async fn upsert(&self, ws: WorkspaceDto) -> CoreResult<()> {
        let mut w = self.inner.write().await;
        if let Some(p) = w.iter().position(|x| x.id==ws.id) { w[p]=ws; } else { w.push(ws); }
        Ok(())
    }
    async fn delete(&self, id: Uuid) -> CoreResult<()> { self.inner.write().await.retain(|w| w.id!=id); Ok(()) }
}
