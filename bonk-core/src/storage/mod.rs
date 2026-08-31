//! Storage abstraction - replaces SwiftData on Win/Linux
//! Trait stays pure, impl can be SQLite (rusqlite) or in-memory for tests.

use async_trait::async_trait;
use crate::error::CoreResult;
use crate::models::HostItemDto;
use uuid::Uuid;

#[async_trait]
pub trait HostStore: Send + Sync {
    async fn list(&self) -> CoreResult<Vec<HostItemDto>>;
    async fn get(&self, id: Uuid) -> CoreResult<Option<HostItemDto>>;
    async fn upsert(&self, host: HostItemDto) -> CoreResult<()>;
    async fn delete(&self, id: Uuid) -> CoreResult<()>;
}

/// In-memory impl - useful for tests and initial Tauri dev without DB
pub struct InMemoryHostStore {
    inner: std::sync::Arc<tokio::sync::RwLock<Vec<HostItemDto>>>,
}

impl InMemoryHostStore {
    pub fn new() -> Self {
        Self { inner: std::sync::Arc::new(tokio::sync::RwLock::new(vec![])) }
    }
}

impl Default for InMemoryHostStore {
    fn default() -> Self { Self::new() }
}

#[async_trait]
impl HostStore for InMemoryHostStore {
    async fn list(&self) -> CoreResult<Vec<HostItemDto>> {
        Ok(self.inner.read().await.clone())
    }
    async fn get(&self, id: Uuid) -> CoreResult<Option<HostItemDto>> {
        Ok(self.inner.read().await.iter().find(|h| h.id == id).cloned())
    }
    async fn upsert(&self, host: HostItemDto) -> CoreResult<()> {
        let mut w = self.inner.write().await;
        if let Some(pos) = w.iter().position(|h| h.id == host.id) {
            w[pos] = host;
        } else {
            w.push(host);
        }
        Ok(())
    }
    async fn delete(&self, id: Uuid) -> CoreResult<()> {
        self.inner.write().await.retain(|h| h.id != id);
        Ok(())
    }
}

/// SQLite impl - enabled with `storage-sqlite` feature
#[cfg(feature = "storage-sqlite")]
pub mod sqlite {
    use super::*;
    use rusqlite::{params, Connection};
    use std::sync::Mutex;

    pub struct SqliteHostStore {
        conn: Mutex<Connection>,
    }

    impl SqliteHostStore {
        pub fn new(path: &str) -> CoreResult<Self> {
            let conn = Connection::open(path).map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
            conn.execute_batch(
                "CREATE TABLE IF NOT EXISTS hosts (
                    id TEXT PRIMARY KEY,
                    json TEXT NOT NULL
                );"
            ).map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
            Ok(Self { conn: Mutex::new(conn) })
        }
    }

    #[async_trait]
    impl HostStore for SqliteHostStore {
        async fn list(&self) -> CoreResult<Vec<HostItemDto>> {
            let conn = self.conn.lock().unwrap();
            let mut stmt = conn.prepare("SELECT json FROM hosts").map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
            let rows = stmt.query_map([], |row| row.get::<_, String>(0)).map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
            let mut out = vec![];
            for r in rows {
                let s = r.map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
                let dto: HostItemDto = serde_json::from_str(&s).map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
                out.push(dto);
            }
            Ok(out)
        }
        async fn get(&self, id: Uuid) -> CoreResult<Option<HostItemDto>> {
            let conn = self.conn.lock().unwrap();
            let mut stmt = conn.prepare("SELECT json FROM hosts WHERE id=?1").map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
            let mut rows = stmt.query(params![id.to_string()]).map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
            if let Some(row) = rows.next().map_err(|e| crate::error::CoreError::Storage(e.to_string()))? {
                let s: String = row.get(0).map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
                Ok(Some(serde_json::from_str(&s).map_err(|e| crate::error::CoreError::Storage(e.to_string()))?))
            } else { Ok(None) }
        }
        async fn upsert(&self, host: HostItemDto) -> CoreResult<()> {
            let json = serde_json::to_string(&host).map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
            self.conn.lock().unwrap().execute("INSERT OR REPLACE INTO hosts(id,json) VALUES(?1,?2)", params![host.id.to_string(), json])
                .map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
            Ok(())
        }
        async fn delete(&self, id: Uuid) -> CoreResult<()> {
            self.conn.lock().unwrap().execute("DELETE FROM hosts WHERE id=?1", params![id.to_string()])
                .map_err(|e| crate::error::CoreError::Storage(e.to_string()))?;
            Ok(())
        }
    }
}
