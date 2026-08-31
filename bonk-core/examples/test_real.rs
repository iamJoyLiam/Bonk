use bonk_core::models::{AuthType, SshConnectionConfig, TerminalSize};
use bonk_core::ssh::SshConnector;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    bonk_core::init();
    let config = SshConnectionConfig {
        host: "192.168.100.50".into(),
        port: 22,
        username: "root".into(),
        auth_type: AuthType::Password,
        secret: Some("Nextenso_33@2025".into()),
        ..Default::default()
    };
    println!("connecting to {}@{}:{} ...", config.username, config.host, config.port);
    let connector = SshConnector::new(config);
    let t0 = std::time::Instant::now();
    let session = connector.connect().await?;
    println!("connected in {:?} (if fallback mock, check auth)", t0.elapsed());

    // Test execute
    let res = session.execute("hostname; whoami; pwd; uname -a").await?;
    println!("execute output:\n{}", res.output);

    // Test PTY
    println!("opening PTY 80x24 ...");
    let pty = session.open_pty(TerminalSize { cols: 80, rows: 24 }).await?;
    // Send ls
    pty.write(b"echo hello-from-bonk-core\n").await?;
    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
    // Drain output
    for _ in 0..3 {
        match tokio::time::timeout(std::time::Duration::from_millis(800), pty.next_output()).await {
            Ok(Some(data)) => print!("{}", String::from_utf8_lossy(&data)),
            _ => break,
        }
    }
    println!("\nPTY test done");
    pty.close().await?;
    session.close().await?;
    println!("closed");
    Ok(())
}
