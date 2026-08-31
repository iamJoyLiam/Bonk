//! Port forwarding - Local/Remote/Dynamic
//! Mirrors BonkMac PortForward + NativePortForward + PortForwardService

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use crate::error::CoreResult;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ForwardType {
    Local,
    Remote,
    Dynamic, // SOCKS5
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PortForwardDto {
    pub id: Uuid,
    pub host_id: Uuid,
    pub forward_type: ForwardType,
    pub local_host: String,
    pub local_port: u16,
    pub remote_host: String,
    pub remote_port: u16,
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForwardHandle {
    pub id: Uuid,
    pub forward: PortForwardDto,
    pub state: ForwardState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ForwardState {
    Active,
    Stopped,
    Error,
}

#[async_trait]
pub trait PortForwardService: Send + Sync {
    async fn start(&self, forward: PortForwardDto) -> CoreResult<ForwardHandle>;
    async fn stop(&self, handle_id: Uuid) -> CoreResult<()>;
    async fn list(&self) -> CoreResult<Vec<ForwardHandle>>;
}

pub struct InMemoryForwardService {
    inner: std::sync::Arc<tokio::sync::RwLock<Vec<ForwardHandle>>>,
}

impl InMemoryForwardService {
    pub fn new() -> Self { Self { inner: std::sync::Arc::new(tokio::sync::RwLock::new(vec![])) } }
}

impl Default for InMemoryForwardService { fn default() -> Self { Self::new() } }

#[async_trait]
impl PortForwardService for InMemoryForwardService {
    async fn start(&self, forward: PortForwardDto) -> CoreResult<ForwardHandle> {
        // Real impl: session.channel_open_direct_tcpip / tcpip_forward / dynamic
        let h = ForwardHandle { id: Uuid::new_v4(), forward, state: ForwardState::Active };
        self.inner.write().await.push(h.clone());
        tracing::info!("forward start {:?}", h.id);
        Ok(h)
    }
    async fn stop(&self, handle_id: Uuid) -> CoreResult<()> {
        self.inner.write().await.retain(|h| h.id != handle_id);
        Ok(())
    }
    async fn list(&self) -> CoreResult<Vec<ForwardHandle>> {
        Ok(self.inner.read().await.clone())
    }
}
