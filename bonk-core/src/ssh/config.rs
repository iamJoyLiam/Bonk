use serde::{Deserialize, Serialize};

/// SSH client config - mirrors BonkMac's SSHConnectionConfigBuilder output
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshClientConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub timeout_secs: u64,
    pub keepalive_secs: u64,
    /// Preferred key exchange algorithms (optional override)
    pub kex_algorithms: Option<Vec<String>>,
    /// Host key algorithms
    pub host_key_algorithms: Option<Vec<String>>,
}

impl Default for SshClientConfig {
    fn default() -> Self {
        Self {
            host: String::new(),
            port: 22,
            username: String::new(),
            timeout_secs: 15,
            keepalive_secs: 30,
            kex_algorithms: None,
            host_key_algorithms: None,
        }
    }
}
