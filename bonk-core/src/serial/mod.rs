//! Serial port abstraction
//! Mac: IOKit  -> Win: serialport crate (COMx)
//! Trait stays identical, impl is platform-specific.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use crate::error::CoreResult;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SerialPortInfo {
    pub name: String, // "COM3" on Win, "/dev/tty.usbserial-*" on Mac
    pub display_name: String,
    pub manufacturer: Option<String>,
    pub product: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SerialConfig {
    pub port: String,
    pub baud_rate: u32,
    pub data_bits: u8,
    pub stop_bits: u8,
    pub parity: String, // "none" | "odd" | "even"
    pub flow_control: String, // "none" | "hardware" | "software"
}

impl Default for SerialConfig {
    fn default() -> Self {
        Self { port: "COM1".into(), baud_rate: 115200, data_bits: 8, stop_bits: 1, parity: "none".into(), flow_control: "none".into() }
    }
}

#[async_trait]
pub trait SerialService: Send + Sync {
    async fn list_ports(&self) -> CoreResult<Vec<SerialPortInfo>>;
    async fn open(&self, config: SerialConfig) -> CoreResult<String>; // returns handle id
    async fn write(&self, handle_id: &str, data: &[u8]) -> CoreResult<()>;
    async fn close(&self, handle_id: &str) -> CoreResult<()>;
}

pub struct InMemorySerialService;

impl Default for InMemorySerialService { fn default() -> Self { Self } }

#[async_trait]
impl SerialService for InMemorySerialService {
    async fn list_ports(&self) -> CoreResult<Vec<SerialPortInfo>> {
        #[cfg(feature = "serial")]
        {
            if let Ok(ports) = serialport::available_ports() {
                if !ports.is_empty() {
                    let mut out = Vec::new();
                    for p in ports {
                        let display = format!("{} - {:?}", p.port_name, p.port_type);
                        out.push(SerialPortInfo { name: p.port_name.clone(), display_name: display, manufacturer: None, product: None });
                    }
                    return Ok(out);
                }
            }
        }
        // Mock fallback (also used when feature disabled or no ports found)
        Ok(vec![
            SerialPortInfo { name: "COM1".into(), display_name: "COM1 - Mock Serial".into(), manufacturer: None, product: None },
            SerialPortInfo { name: "COM3".into(), display_name: "COM3 - USB Serial".into(), manufacturer: Some("FTDI".into()), product: Some("FT232R".into()) },
        ])
    }
    async fn open(&self, config: SerialConfig) -> CoreResult<String> {
        tracing::info!("serial open {} @ {}", config.port, config.baud_rate);
        Ok(uuid::Uuid::new_v4().to_string())
    }
    async fn write(&self, _handle_id: &str, _data: &[u8]) -> CoreResult<()> { Ok(()) }
    async fn close(&self, _handle_id: &str) -> CoreResult<()> { Ok(()) }
}
