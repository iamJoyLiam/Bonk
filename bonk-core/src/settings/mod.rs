//! Settings / UserPreferences - singleton + general config
//! Mirrors BonkMac Models/Session/UserPreferences + Themes/AppStyle

use serde::{Deserialize, Serialize};
use crate::error::CoreResult;
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserPreferencesDto {
    pub theme: String, // "system" | "light" | "dark"
    pub font_family: String,
    pub font_size: u8,
    pub keep_alive_secs: u64,
    pub reconnect_enabled: bool,
    pub reconnect_max_retries: u32,
    pub quake_hotkey: String,
    pub log_colorizer_enabled: bool,
    pub ai_enabled: bool,
    pub language: String, // "en" | "zh-Hans"
}

impl Default for UserPreferencesDto {
    fn default() -> Self {
        Self {
            theme: "system".into(),
            font_family: "JetBrains Mono".into(),
            font_size: 13,
            keep_alive_secs: 30,
            reconnect_enabled: true,
            reconnect_max_retries: 5,
            quake_hotkey: "Ctrl+`".into(),
            log_colorizer_enabled: true,
            ai_enabled: true,
            language: "zh-Hans".into(),
        }
    }
}

#[async_trait::async_trait]
pub trait SettingsStore: Send + Sync {
    async fn load(&self) -> CoreResult<UserPreferencesDto>;
    async fn save(&self, prefs: UserPreferencesDto) -> CoreResult<()>;
}

pub struct InMemorySettingsStore { inner: Arc<RwLock<UserPreferencesDto>> }
impl InMemorySettingsStore { pub fn new() -> Self { Self { inner: Arc::new(RwLock::new(UserPreferencesDto::default())) } } }
impl Default for InMemorySettingsStore { fn default() -> Self { Self::new() } }

#[async_trait::async_trait]
impl SettingsStore for InMemorySettingsStore {
    async fn load(&self) -> CoreResult<UserPreferencesDto> { Ok(self.inner.read().await.clone()) }
    async fn save(&self, prefs: UserPreferencesDto) -> CoreResult<()> { *self.inner.write().await = prefs; Ok(()) }
}
