//! cargo run --example connect

use bonk_core::ssh::SshConnector;
use bonk_core::models::{AuthType, SshConnectionConfig, TerminalSize};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    bonk_core::init();

    let config = SshConnectionConfig {
        host: "127.0.0.1".into(),
        port: 22,
        username: "test".into(),
        auth_type: AuthType::Password,
        secret: Some("password".into()),
        ..Default::default()
    };

    let connector = SshConnector::new(config);
    let session = connector.connect().await?;
    println!("connected (mock) -> open PTY 80x24");
    let pty = session.open_pty(TerminalSize { cols: 80, rows: 24 }).await?;
    pty.write(b"ls\n").await?;
    // Read one output chunk
    if let Some(data) = tokio::time::timeout(std::time::Duration::from_secs(2), pty.next_output()).await.ok().flatten() {
        println!("pty output: {}", String::from_utf8_lossy(&data));
    }
    pty.close().await?;
    session.close().await?;
    println!("done");
    Ok(())
}
