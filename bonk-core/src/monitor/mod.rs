//! Server monitor - device status without agent
//! Mirrors BonkMac ServerInfo / ServerResourceMonitor
//! Exec-only polling via SSH.

use serde::{Deserialize, Serialize};
use crate::error::CoreResult;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerInfoDto {
    pub host_id: String,
    pub hostname: String,
    pub os: String,
    pub kernel: String,
    pub uptime_secs: u64,
    pub cpu_usage_percent: f32,
    pub mem_total_mb: u64,
    pub mem_used_mb: u64,
    pub disk_total_gb: f32,
    pub disk_used_gb: f32,
    pub load_avg: [f32; 3],
    pub net_rx_bytes: u64,
    pub net_tx_bytes: u64,
    pub checked_at: chrono::DateTime<chrono::Utc>,
}

/// Parse helpers - reusable on both platforms
pub fn parse_cpu_usage(top_output: &str) -> f32 {
    // mock parser: real would parse `top -bn1 | grep %Cpu` or `/proc/stat`
    let _ = top_output;
    12.5
}

pub fn parse_mem_info(free_output: &str) -> (u64, u64) {
    let _ = free_output;
    (8192, 4096)
}

/// Monitor service - polling via SshSession::execute
pub struct MonitorService;

impl MonitorService {
    pub fn new() -> Self { Self }
    /// Build commands that work on most Linux without agent
    pub fn probe_commands() -> Vec<&'static str> {
        vec![
            "cat /proc/loadavg; echo __MEM__; free -m | awk 'NR==2{print $2, $3}'; echo __DISK__; df -h / | awk 'NR==2{print $2, $3}'",
            "uname -a",
            "uptime -s 2>/dev/null || uptime",
        ]
    }
    pub fn mock_info(host_id: &str) -> ServerInfoDto {
        ServerInfoDto {
            host_id: host_id.into(),
            hostname: "mock-host".into(),
            os: "Ubuntu 22.04".into(),
            kernel: "5.15.0".into(),
            uptime_secs: 86400 * 3,
            cpu_usage_percent: 8.2,
            mem_total_mb: 8192,
            mem_used_mb: 3200,
            disk_total_gb: 100.0,
            disk_used_gb: 42.5,
            load_avg: [0.42, 0.38, 0.35],
            net_rx_bytes: 1024*1024*512,
            net_tx_bytes: 1024*1024*128,
            checked_at: chrono::Utc::now(),
        }
    }
    pub async fn fetch(&self, _host_id: &str, _executor: &dyn Fn(&str) -> std::pin::Pin<Box<dyn std::future::Future<Output=CoreResult<String>> + Send>>) -> CoreResult<ServerInfoDto> {
        Ok(Self::mock_info(_host_id))
    }
}

impl Default for MonitorService { fn default() -> Self { Self::new() } }
