//! Team - discovery / relay / vault
//! Mirrors BonkMac Services/Team/*
//! Mock-first, real impl would be WebSocket relay.

use serde::{Deserialize, Serialize};
use crate::error::CoreResult;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamMemberDto {
    pub id: Uuid,
    pub name: String,
    pub host: String,
    pub online: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamSessionDto {
    pub id: Uuid,
    pub owner_id: Uuid,
    pub title: String,
    pub shared_session_ids: Vec<String>,
}

#[async_trait::async_trait]
pub trait TeamService: Send + Sync {
    async fn discover(&self) -> CoreResult<Vec<TeamMemberDto>>;
    async fn start_share(&self, session_ids: Vec<String>, title: &str) -> CoreResult<TeamSessionDto>;
    async fn stop_share(&self, team_session_id: Uuid) -> CoreResult<()>;
    async fn join(&self, invite_code: &str) -> CoreResult<TeamSessionDto>;
}

pub struct InMemoryTeamService {
    members: Arc<RwLock<Vec<TeamMemberDto>>>,
    sessions: Arc<RwLock<Vec<TeamSessionDto>>>,
}

impl InMemoryTeamService {
    pub fn new() -> Self { Self { members: Arc::new(RwLock::new(vec![])), sessions: Arc::new(RwLock::new(vec![])) } }
}
impl Default for InMemoryTeamService { fn default() -> Self { Self::new() } }

#[async_trait::async_trait]
impl TeamService for InMemoryTeamService {
    async fn discover(&self) -> CoreResult<Vec<TeamMemberDto>> {
        Ok(self.members.read().await.clone())
    }
    async fn start_share(&self, session_ids: Vec<String>, title: &str) -> CoreResult<TeamSessionDto> {
        let s = TeamSessionDto { id: Uuid::new_v4(), owner_id: Uuid::new_v4(), title: title.into(), shared_session_ids: session_ids };
        self.sessions.write().await.push(s.clone());
        Ok(s)
    }
    async fn stop_share(&self, id: Uuid) -> CoreResult<()> { self.sessions.write().await.retain(|s| s.id!=id); Ok(()) }
    async fn join(&self, invite_code: &str) -> CoreResult<TeamSessionDto> {
        let _ = invite_code;
        Ok(TeamSessionDto { id: Uuid::new_v4(), owner_id: Uuid::new_v4(), title: "joined".into(), shared_session_ids: vec![] })
    }
}
