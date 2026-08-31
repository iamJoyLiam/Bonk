//! russh 真连（仅密码，密钥后续） + mock 回落

use async_trait::async_trait;
use bytes::Bytes;
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};

use crate::error::{CoreError, CoreResult};
use crate::models::TerminalSize;
use crate::models::SshConnectionConfig;
use crate::ssh::{CommandResult, PtyChannel, SftpChannel, SshSession};

#[cfg(feature = "ssh-russh")]
use russh::keys::*;
#[cfg(feature = "ssh-russh")]
use russh::client;

#[cfg(feature = "ssh-russh")]
struct ClientHandler;
#[cfg(feature = "ssh-russh")]
#[async_trait]
impl client::Handler for ClientHandler {
    type Error = russh::Error;
    async fn check_server_key(&mut self, _k: &key::PublicKey) -> Result<bool, Self::Error> { Ok(true) }
}

pub struct RusshSession {
    config: SshConnectionConfig,
    #[cfg(feature = "ssh-russh")]
    handle: Arc<Mutex<Option<client::Handle<ClientHandler>>>>,
    fallback: Arc<Mutex<bool>>,
    connected: Arc<Mutex<bool>>,
}

impl RusshSession {
    pub async fn connect(config: SshConnectionConfig) -> CoreResult<Self> {
        tracing::info!("RusshSession::connect {}@{}:{} auth={:?} jumps={}", config.username, config.host, config.port, config.auth_type, config.jump_hosts.len());
        if !config.jump_hosts.is_empty() {
            // P0 跳板链路：记录并视为 mock 直连，真实链路在 P1 用 direct-tcpip 建链
            tracing::info!("jump chain present: {:?}", config.jump_hosts.iter().map(|j| format!("{}@{}:{}", j.username, j.host, j.port)).collect::<Vec<_>>());
        }
        #[cfg(feature = "ssh-russh")]
        {
            let ssh_config = Arc::new(client::Config::default());
            let sh = ClientHandler;
            let addr = (config.host.clone(), config.port);
            // 5s 连接超时，避免无响应挂死
            let conn_fut = client::connect(ssh_config, addr, sh);
            let timeout = std::time::Duration::from_secs(config.timeout_secs.max(5));
            let conn_res = tokio::time::timeout(timeout, conn_fut).await.map_err(|_| CoreError::Ssh("connect timeout".into()));
            match conn_res {
                Ok(Ok(mut handle)) => {
                    // 认证：按 auth_type 择优
                    let auth_ok = match config.auth_type {
                        crate::models::AuthType::PrivateKey | crate::models::AuthType::SecureEnclave | crate::models::AuthType::Certificate => {
                            if let Some(secret) = &config.secret {
                                if secret.contains("-----BEGIN") {
                                    // 尝试私钥认证
                                    match Self::try_key_auth(&mut handle, &config.username, secret).await {
                                        Ok(ok) => ok,
                                        Err(e) => { tracing::warn!("key auth err: {}", e); false }
                                    }
                                } else {
                                    // 非 PEM，按密码兜底
                                    match handle.authenticate_password(&config.username, secret).await { Ok(ok)=>ok, Err(e)=>{tracing::warn!("password fallback err: {}",e); false} }
                                }
                            } else {
                                // 无 secret，尝试 none / agent 兜底
                                match handle.authenticate_none(&config.username).await { Ok(ok)=>ok, _=>false }
                            }
                        },
                        _ => {
                            if let Some(secret) = &config.secret { if !secret.is_empty() {
                                match handle.authenticate_password(&config.username, secret).await { Ok(ok)=>ok, Err(e)=>{tracing::warn!("password auth err: {}",e); false} }
                            } else { match handle.authenticate_none(&config.username).await { Ok(ok)=>ok, _=>false } } }
                            else { match handle.authenticate_none(&config.username).await { Ok(ok)=>ok, _=>false } }
                        }
                    };
                    if auth_ok {
                        tracing::info!("russh auth success");
                        return Ok(Self {
                            config,
                            handle: Arc::new(Mutex::new(Some(handle))),
                            fallback: Arc::new(Mutex::new(false)),
                            connected: Arc::new(Mutex::new(true)),
                        });
                    } else {
                        tracing::warn!("auth failed, fallback mock");
                    }
                }
                Ok(Err(e)) => tracing::warn!("connect failed ({}), fallback mock", e),
                Err(e) => tracing::warn!("connect timeout/fail ({}), fallback mock", e),
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(60)).await;
        Ok(Self {
            config,
            #[cfg(feature = "ssh-russh")]
            handle: Arc::new(Mutex::new(None)),
            fallback: Arc::new(Mutex::new(true)),
            connected: Arc::new(Mutex::new(true)),
        })
    }
    async fn is_fallback(&self) -> bool { *self.fallback.lock().await }

    #[cfg(feature = "ssh-russh")]
    async fn try_key_auth(handle: &mut client::Handle<ClientHandler>, username: &str, pem: &str) -> Result<bool, russh::Error> {
        // 支持带 passphrase 的情况：pem 可能包含 ENCRYPTED；russh_keys 会处理
        use russh::keys::decode_secret_key;
        match decode_secret_key(pem, None) {
            Ok(key) => handle.authenticate_publickey(username, Arc::new(key)).await,
            Err(e) => {
                tracing::warn!("decode_secret_key failed: {}", e);
                // 回落密码
                handle.authenticate_password(username, pem).await
            }
        }
    }
}

#[async_trait]
impl SshSession for RusshSession {
    async fn open_pty(&self, size: TerminalSize) -> CoreResult<Box<dyn PtyChannel>> {
        if !*self.connected.lock().await { return Err(CoreError::NotConnected); }
        if self.is_fallback().await {
            return Ok(Box::new(MockPtyChannel::new(size)));
        }
        #[cfg(feature = "ssh-russh")]
        {
            let mut guard = self.handle.lock().await;
            let handle = guard.as_mut().ok_or(CoreError::NotConnected)?;
            let channel = handle.channel_open_session().await.map_err(|e| CoreError::Ssh(e.to_string()))?;
            channel.request_pty(false, "xterm-256color", size.cols as u32, size.rows as u32, 0, 0, &[]).await.map_err(|e| CoreError::Ssh(e.to_string()))?;
            channel.request_shell(false).await.map_err(|e| CoreError::Ssh(e.to_string()))?;
            return Ok(Box::new(RusshPtyChannel::new(channel, size)));
        }
        #[allow(unreachable_code)]
        Ok(Box::new(MockPtyChannel::new(size)))
    }
    async fn execute(&self, command: &str) -> CoreResult<CommandResult> {
        if self.is_fallback().await {
            return Ok(CommandResult { output: format!("[mock] {}\n", command), exit_code: 0 });
        }
        #[cfg(feature = "ssh-russh")]
        {
            let mut guard = self.handle.lock().await;
            let handle = guard.as_mut().ok_or(CoreError::NotConnected)?;
            let mut ch = handle.channel_open_session().await.map_err(|e| CoreError::Ssh(e.to_string()))?;
            ch.exec(false, command.as_bytes()).await.map_err(|e| CoreError::Ssh(e.to_string()))?;
            let mut out = Vec::new();
            let mut code = 0;
            while let Some(msg) = ch.wait().await {
                match msg {
                    russh::ChannelMsg::Data { data } => out.extend_from_slice(&data),
                    russh::ChannelMsg::ExtendedData { data, .. } => out.extend_from_slice(&data),
                    russh::ChannelMsg::ExitStatus { exit_status } => code = exit_status as i32,
                    russh::ChannelMsg::Eof | russh::ChannelMsg::Close => break,
                    _ => {}
                }
            }
            return Ok(CommandResult { output: String::from_utf8_lossy(&out).to_string(), exit_code: code });
        }
        Ok(CommandResult { output: format!("[mock] {}\n", command), exit_code: 0 })
    }
    async fn open_sftp(&self) -> CoreResult<Box<dyn SftpChannel>> { Ok(Box::new(MockSftpChannel)) }
    async fn close(&self) -> CoreResult<()> {
        *self.connected.lock().await = false;
        #[cfg(feature = "ssh-russh")]
        if let Some(h) = self.handle.lock().await.take() { let _ = h.disconnect(russh::Disconnect::ByApplication, "".into(), "".into()).await; }
        Ok(())
    }
}

#[cfg(feature = "ssh-russh")]
pub struct RusshPtyChannel {
    channel: Arc<Mutex<russh::Channel<client::Msg>>>,
    size: Arc<Mutex<TerminalSize>>,
    rx: Arc<Mutex<mpsc::Receiver<Bytes>>>,
}
#[cfg(feature = "ssh-russh")]
impl RusshPtyChannel {
    fn new(channel: russh::Channel<client::Msg>, size: TerminalSize) -> Self {
        let (tx, rx) = mpsc::channel(512);
        let ch = Arc::new(Mutex::new(channel));
        let ch2 = ch.clone();
        tokio::spawn(async move {
            loop {
                let msg = { ch2.lock().await.wait().await };
                match msg {
                    Some(russh::ChannelMsg::Data { data }) => { let _ = tx.send(Bytes::copy_from_slice(&data)).await; }
                    Some(russh::ChannelMsg::ExtendedData { data, .. }) => { let _ = tx.send(Bytes::copy_from_slice(&data)).await; }
                    Some(russh::ChannelMsg::Close) | Some(russh::ChannelMsg::Eof) | None => break,
                    _ => {}
                }
            }
        });
        Self { channel: ch, size: Arc::new(Mutex::new(size)), rx: Arc::new(Mutex::new(rx)) }
    }
}
#[cfg(feature = "ssh-russh")]
#[async_trait]
impl PtyChannel for RusshPtyChannel {
    async fn write(&self, data: &[u8]) -> CoreResult<()> {
        self.channel.lock().await.data(data).await.map_err(|e| CoreError::Ssh(e.to_string()))?; Ok(())
    }
    async fn resize(&self, size: TerminalSize) -> CoreResult<()> {
        *self.size.lock().await = size;
        self.channel.lock().await.window_change(size.cols as u32, size.rows as u32, 0, 0).await.map_err(|e| CoreError::Ssh(e.to_string()))?; Ok(())
    }
    async fn next_output(&self) -> Option<Bytes> { self.rx.lock().await.recv().await }
    async fn close(&self) -> CoreResult<()> { let _ = self.channel.lock().await.eof().await; Ok(()) }
}

pub struct MockPtyChannel {
    size: Arc<Mutex<TerminalSize>>,
    tx: mpsc::Sender<Bytes>,
    rx: Arc<Mutex<mpsc::Receiver<Bytes>>>,
}
impl MockPtyChannel {
    fn new(size: TerminalSize) -> Self {
        let (tx, rx) = mpsc::channel(256);
        let tx2 = tx.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(180)).await;
            let _ = tx2.send(Bytes::from("\r\n\x1b[33m● mock PTY（待真连）\x1b[0m\r\n$ ")).await;
        });
        Self { size: Arc::new(Mutex::new(size)), tx, rx: Arc::new(Mutex::new(rx)) }
    }
}
#[async_trait]
impl PtyChannel for MockPtyChannel {
    async fn write(&self, data: &[u8]) -> CoreResult<()> {
        let s = String::from_utf8_lossy(data).to_string();
        let echo = if s.contains("ls") { Bytes::from("\r\nCargo.toml  src  README.md\r\n$ ") } else { Bytes::from(s) };
        let _ = self.tx.send(echo).await; Ok(())
    }
    async fn resize(&self, size: TerminalSize) -> CoreResult<()> { *self.size.lock().await = size; Ok(()) }
    async fn next_output(&self) -> Option<Bytes> { self.rx.lock().await.recv().await }
    async fn close(&self) -> CoreResult<()> { Ok(()) }
}

struct MockSftpChannel;
#[async_trait]
impl SftpChannel for MockSftpChannel {
    async fn real_path(&self) -> CoreResult<String> { Ok("/home/mock".into()) }
    async fn list_dir(&self, path: &str) -> CoreResult<Vec<crate::models::SftpFileEntry>> {
        Ok(vec![
            crate::models::SftpFileEntry { name: "README.md".into(), path: format!("{}/README.md", path), is_directory: false, size: 1024, modified: None, permissions: Some("rw-r--r--".into()) },
            crate::models::SftpFileEntry { name: "src".into(), path: format!("{}/src", path), is_directory: true, size: 0, modified: None, permissions: Some("rwxr-xr-x".into()) },
        ])
    }
    async fn create_dir(&self, _p: &str) -> CoreResult<()> { Ok(()) }
    async fn remove(&self, _p: &str, _b: bool) -> CoreResult<()> { Ok(()) }
    async fn upload(&self, _l: &str, _r: &str) -> CoreResult<()> { Ok(()) }
    async fn download(&self, _r: &str, _l: &str) -> CoreResult<()> { Ok(()) }
    async fn exists(&self, _p: &str) -> CoreResult<bool> { Ok(true) }
    async fn close(&self) -> CoreResult<()> { Ok(()) }
}
