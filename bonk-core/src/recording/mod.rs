//! Session recording - asciicast v2
//! Mirrors BonkMac SessionRecordingService

use serde::{Deserialize, Serialize};
use crate::error::CoreResult;
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingMeta {
    pub id: String,
    pub session_id: String,
    pub host_name: String,
    pub started_at: chrono::DateTime<chrono::Utc>,
    pub duration_secs: Option<u64>,
    pub file_path: String, // local path to .cast file
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingEvent {
    pub time: f64, // secs since start
    pub data: String,
    pub event_type: String, // "o" output, "i" input, "r" resize
}

pub struct RecordingService {
    inner: Arc<RwLock<Vec<RecordingMeta>>>,
}

impl RecordingService {
    pub fn new() -> Self { Self { inner: Arc::new(RwLock::new(vec![])) } }
    pub async fn start(&self, session_id: &str, host_name: &str) -> CoreResult<RecordingMeta> {
        let dir = std::env::temp_dir().join("bonk-recordings");
        let _ = tokio::fs::create_dir_all(&dir).await;
        let path = dir.join(format!("bonk-{}.cast", uuid::Uuid::new_v4()));
        let meta = RecordingMeta {
            id: uuid::Uuid::new_v4().to_string(),
            session_id: session_id.into(),
            host_name: host_name.into(),
            started_at: chrono::Utc::now(),
            duration_secs: None,
            file_path: path.to_string_lossy().to_string(),
        };
        // asciicast v2 header
        let header = serde_json::json!({"version":2,"width":120,"height":32,"timestamp": meta.started_at.timestamp(),"env":{"TERM":"xterm-256color"}});
        let _ = tokio::fs::write(&path, format!("{}\n", header)).await;
        self.inner.write().await.push(meta.clone());
        tracing::info!("recording start {} -> {}", meta.id, meta.file_path);
        Ok(meta)
    }
    pub async fn stop(&self, id: &str) -> CoreResult<()> {
        let mut w = self.inner.write().await;
        if let Some(m) = w.iter_mut().find(|m| m.id == id) {
            m.duration_secs = Some((chrono::Utc::now() - m.started_at).num_seconds() as u64);
        }
        Ok(())
    }
    pub async fn list(&self) -> CoreResult<Vec<RecordingMeta>> {
        Ok(self.inner.read().await.clone())
    }
    /// Write asciicast v2 event: [time, type, data]
    pub async fn append(&self, id: &str, event: RecordingEvent) -> CoreResult<()> {
        let path = {
            let r = self.inner.read().await;
            r.iter().find(|m| m.id==id).map(|m| m.file_path.clone())
        };
        if let Some(p) = path {
            let line = serde_json::json!([event.time, event.event_type, event.data]);
            let mut file = tokio::fs::OpenOptions::new().append(true).create(true).open(&p).await.map_err(|e| crate::error::CoreError::Io(e.to_string()))?;
            use tokio::io::AsyncWriteExt;
            let mut buf = serde_json::to_string(&line).map_err(|e| crate::error::CoreError::Io(e.to_string()))?;
            buf.push('\n');
            file.write_all(buf.as_bytes()).await.map_err(|e| crate::error::CoreError::Io(e.to_string()))?;
        }
        Ok(())
    }
}

impl Default for RecordingService { fn default() -> Self { Self::new() } }
