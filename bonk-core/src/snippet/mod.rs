//! Snippet & Command history
//! Mirrors BonkMac Models/Features/Snippet + CommandHistory

use serde::{Deserialize, Serialize};
use crate::error::CoreResult;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnippetDto {
    pub id: Uuid,
    pub name: String,
    pub content: String,
    pub description: Option<String>,
    pub tags: Vec<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandHistoryDto {
    pub id: Uuid,
    pub host_id: Option<Uuid>,
    pub command: String,
    pub executed_at: chrono::DateTime<chrono::Utc>,
    pub exit_code: Option<i32>,
}

#[async_trait::async_trait]
pub trait SnippetStore: Send + Sync {
    async fn list(&self) -> CoreResult<Vec<SnippetDto>>;
    async fn upsert(&self, s: SnippetDto) -> CoreResult<()>;
    async fn delete(&self, id: Uuid) -> CoreResult<()>;
}

pub struct InMemorySnippetStore { inner: Arc<RwLock<Vec<SnippetDto>>> }
impl InMemorySnippetStore { pub fn new() -> Self { Self { inner: Arc::new(RwLock::new(vec![])) } } }
impl Default for InMemorySnippetStore { fn default() -> Self { Self::new() } }

#[async_trait::async_trait]
impl SnippetStore for InMemorySnippetStore {
    async fn list(&self) -> CoreResult<Vec<SnippetDto>> { Ok(self.inner.read().await.clone()) }
    async fn upsert(&self, s: SnippetDto) -> CoreResult<()> {
        let mut w = self.inner.write().await;
        if let Some(p)=w.iter().position(|x| x.id==s.id){ w[p]=s; } else { w.push(s); }
        Ok(())
    }
    async fn delete(&self, id: Uuid) -> CoreResult<()> { self.inner.write().await.retain(|x| x.id!=id); Ok(()) }
}

pub struct InMemoryHistoryStore { inner: Arc<RwLock<Vec<CommandHistoryDto>>> }
impl InMemoryHistoryStore { pub fn new() -> Self { Self { inner: Arc::new(RwLock::new(vec![])) } } }
impl Default for InMemoryHistoryStore { fn default() -> Self { Self::new() } }

impl InMemoryHistoryStore {
    pub async fn push(&self, cmd: CommandHistoryDto) -> CoreResult<()> {
        let mut w = self.inner.write().await;
        w.push(cmd);
        if w.len()>2000 { let drain = w.len()-2000; w.drain(0..drain); }
        Ok(())
    }
    pub async fn list(&self, host_id: Option<Uuid>, limit: usize) -> CoreResult<Vec<CommandHistoryDto>> {
        let r = self.inner.read().await;
        let mut v: Vec<_> = r.iter().filter(|h| host_id.map(|id| h.host_id==Some(id)).unwrap_or(true)).cloned().collect();
        v.sort_by(|a,b| b.executed_at.cmp(&a.executed_at));
        v.truncate(limit);
        Ok(v)
    }
}
