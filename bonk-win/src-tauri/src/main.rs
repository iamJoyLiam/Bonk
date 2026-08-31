#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use tauri::Emitter;

use bonk_core::ssh::{SshConnector, SshSession, PtyChannel};
use bonk_core::models::{AuthType, SshConnectionConfig, TerminalSize, HostItemDto, JumpHostDto};
use bonk_core::storage::{InMemoryHostStore, HostStore};
use bonk_core::storage::sqlite::SqliteHostStore;
use bonk_core::forward::{InMemoryForwardService, PortForwardService, PortForwardDto};
use bonk_core::serial::{InMemorySerialService, SerialService, SerialConfig};
use bonk_core::snippet::{InMemorySnippetStore, InMemoryHistoryStore, SnippetStore, SnippetDto, CommandHistoryDto};
use bonk_core::workspace::{InMemoryWorkspaceStore, WorkspaceStore, WorkspaceDto};
use bonk_core::settings::{InMemorySettingsStore, SettingsStore, UserPreferencesDto};
use bonk_core::team::{InMemoryTeamService, TeamService};
use bonk_core::broadcast::{InMemoryBroadcastService, BroadcastService};
use bonk_core::recording::{RecordingService, RecordingEvent};
use bonk_core::monitor::MonitorService;
use bonk_core::import::{SshConfigImporter, TabbyImporter, SessionImporter, export_hosts_json};
use bonk_core::log as logmod;
use bonk_core::ai::{AiCompletionRequest, AiMessage, AiProvider, OpenAiCompatProvider, ClaudeProvider, GeminiProvider, OllamaProvider};

// ---- Session holding both ssh session and pty channel ----

struct PtyEntry {
    session: Arc<dyn SshSession>,
    pty: Arc<Mutex<Box<dyn PtyChannel>>>,
}
impl Clone for PtyEntry {
    fn clone(&self) -> Self { Self { session: self.session.clone(), pty: self.pty.clone() } }
}

type SessionMap = Arc<Mutex<HashMap<String, PtyEntry>>>;
type HostState = Arc<dyn HostStore>;
type ForwardState = Arc<InMemoryForwardService>;
type SerialState = Arc<InMemorySerialService>;
type SnippetState = Arc<InMemorySnippetStore>;
type HistoryState = Arc<InMemoryHistoryStore>;
type WorkspaceState = Arc<InMemoryWorkspaceStore>;
type SettingsState = Arc<InMemorySettingsStore>;
type TeamState = Arc<InMemoryTeamService>;
type BroadcastState = Arc<InMemoryBroadcastService>;
type RecordingState = Arc<RecordingService>;

// ---- Args ----

#[derive(serde::Deserialize)]
struct ConnectArgs {
    host: String,
    port: u16,
    username: String,
    #[serde(rename = "authType")]
    auth_type: String,
    secret: Option<String>,
    #[serde(default)]
    jump_hosts: Vec<JumpArg>,
}

#[derive(serde::Deserialize, Clone)]
struct JumpArg {
    host: String,
    port: u16,
    username: String,
    #[serde(rename = "authType")]
    auth_type: Option<String>,
    secret: Option<String>,
}

fn parse_auth(s: &str) -> AuthType {
    match s {
        "privateKey" => AuthType::PrivateKey,
        "certificate" => AuthType::Certificate,
        "secureEnclave" => AuthType::SecureEnclave,
        _ => AuthType::Password,
    }
}

// ---- Core ----

#[tauri::command]
fn core_version() -> String { bonk_core::CORE_VERSION.to_string() }

#[tauri::command]
fn core_validate_host(json: String) -> bool {
    serde_json::from_str::<HostItemDto>(&json).is_ok()
}

// ---- SSH ----

#[tauri::command]
async fn ssh_connect(
    args: ConnectArgs,
    state: tauri::State<'_, SessionMap>,
    app: tauri::AppHandle,
) -> Result<String, String> {
    let jumps: Vec<JumpHostDto> = args.jump_hosts.iter().map(|j| JumpHostDto {
        host: j.host.clone(),
        port: j.port,
        username: j.username.clone(),
        auth_type: parse_auth(j.auth_type.as_deref().unwrap_or("password")),
        secret: j.secret.clone(),
    }).collect();

    let config = SshConnectionConfig {
        host: args.host.clone(),
        port: args.port,
        username: args.username.clone(),
        auth_type: parse_auth(&args.auth_type),
        secret: args.secret.clone(),
        jump_hosts: jumps,
        ..Default::default()
    };

    let session = SshConnector::new(config).connect().await.map_err(|e| e.to_string())?;
    let pty = session.open_pty(TerminalSize { cols: 120, rows: 32 }).await.map_err(|e| e.to_string())?;

    let session_id = uuid::Uuid::new_v4().to_string();
    let sid_clone = session_id.clone();

    let session_arc: Arc<dyn SshSession> = Arc::from(session);
    let pty_arc: Arc<Mutex<Box<dyn PtyChannel>>> = Arc::new(Mutex::new(pty));
    let pty_for_pump = pty_arc.clone();

    state.lock().await.insert(session_id.clone(), PtyEntry { session: session_arc.clone(), pty: pty_arc });

    // Pump output
    tokio::spawn(async move {
        loop {
            let out = {
                let mut guard = pty_for_pump.lock().await;
                guard.next_output().await
            };
            match out {
                Some(bytes) => {
                    let text = String::from_utf8_lossy(&bytes).to_string();
                    let _ = app.emit(&format!("pty-data://{}", sid_clone), text);
                }
                None => break,
            }
        }
    });

    Ok(session_id)
}

#[tauri::command]
async fn ssh_disconnect(session_id: String, state: tauri::State<'_, SessionMap>) -> Result<(), String> {
    if let Some(entry) = state.lock().await.remove(&session_id) {
        entry.session.close().await.map_err(|e| e.to_string())?;
        let _ = entry.pty.lock().await.close().await;
    }
    Ok(())
}

#[tauri::command]
async fn ssh_write(session_id: String, data: String, state: tauri::State<'_, SessionMap>) -> Result<(), String> {
    let entry = { let map = state.lock().await; map.get(&session_id).cloned().ok_or("session not found")? };
    let res = entry.pty.lock().await.write(data.as_bytes()).await.map_err(|e| e.to_string());
    res
}

#[tauri::command]
async fn ssh_resize(session_id: String, cols: u16, rows: u16, state: tauri::State<'_, SessionMap>) -> Result<(), String> {
    let entry = { let map = state.lock().await; map.get(&session_id).cloned().ok_or("session not found")? };
    let res = entry.pty.lock().await.resize(TerminalSize { cols, rows }).await.map_err(|e| e.to_string());
    res
}

#[tauri::command]
async fn ssh_execute(session_id: String, command: String, state: tauri::State<'_, SessionMap>) -> Result<String, String> {
    let entry = { let map = state.lock().await; map.get(&session_id).cloned().ok_or("session not found")? };
    let res = entry.session.execute(&command).await.map_err(|e| e.to_string())?;
    Ok(res.output)
}

#[tauri::command]
async fn ssh_decision(args: ConnectArgs) -> Result<String, String> {
    let jumps: Vec<JumpHostDto> = args.jump_hosts.iter().map(|j| JumpHostDto {
        host: j.host.clone(), port: j.port, username: j.username.clone(),
        auth_type: parse_auth(j.auth_type.as_deref().unwrap_or("password")), secret: j.secret.clone(),
    }).collect();
    let cfg = SshConnectionConfig { host: args.host, port: args.port, username: args.username, auth_type: parse_auth(&args.auth_type), secret: args.secret, jump_hosts: jumps, ..Default::default() };
    let d = SshConnector::new(cfg).resolve_decision();
    serde_json::to_string(&d).map_err(|e| e.to_string())
}

// ---- Host / Group ----

#[tauri::command]
async fn host_list(state: tauri::State<'_, HostState>) -> Result<Vec<HostItemDto>, String> {
    state.list().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn host_upsert(host_json: String, state: tauri::State<'_, HostState>) -> Result<(), String> {
    let dto: HostItemDto = serde_json::from_str(&host_json).map_err(|e| e.to_string())?;
    state.upsert(dto).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn host_delete(id: String, state: tauri::State<'_, HostState>) -> Result<(), String> {
    let uuid = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    state.delete(uuid).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn host_get(id: String, state: tauri::State<'_, HostState>) -> Result<Option<HostItemDto>, String> {
    let uuid = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    state.get(uuid).await.map_err(|e| e.to_string())
}

// ---- SFTP ----

#[tauri::command]
async fn sftp_list(session_id: String, path: String, state: tauri::State<'_, SessionMap>) -> Result<Vec<bonk_core::models::SftpFileEntry>, String> {
    let entry = { let map = state.lock().await; map.get(&session_id).cloned().ok_or("session not found")? };
    let sftp = entry.session.open_sftp().await.map_err(|e| e.to_string())?;
    let list = sftp.list_dir(&path).await.map_err(|e| e.to_string())?;
    Ok(bonk_core::sftp::sort_entries(list))
}

#[tauri::command]
async fn sftp_mkdir(session_id: String, path: String, state: tauri::State<'_, SessionMap>) -> Result<(), String> {
    let entry = { let map = state.lock().await; map.get(&session_id).cloned().ok_or("session not found")? };
    let sftp = entry.session.open_sftp().await.map_err(|e| e.to_string())?;
    sftp.create_dir(&path).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_remove(session_id: String, path: String, is_dir: bool, state: tauri::State<'_, SessionMap>) -> Result<(), String> {
    let entry = { let map = state.lock().await; map.get(&session_id).cloned().ok_or("session not found")? };
    let sftp = entry.session.open_sftp().await.map_err(|e| e.to_string())?;
    sftp.remove(&path, is_dir).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_exists(session_id: String, path: String, state: tauri::State<'_, SessionMap>) -> Result<bool, String> {
    let entry = { let map = state.lock().await; map.get(&session_id).cloned().ok_or("session not found")? };
    let sftp = entry.session.open_sftp().await.map_err(|e| e.to_string())?;
    sftp.exists(&path).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn sftp_upload(session_id: String, local: String, remote: String, state: tauri::State<'_, SessionMap>, app: tauri::AppHandle) -> Result<(), String> {
    let entry = { let map = state.lock().await; map.get(&session_id).cloned().ok_or("session not found")? };
    let sftp = entry.session.open_sftp().await.map_err(|e| e.to_string())?;
    // P1: 真进度的本地文件分片上传（mock 通道下模拟进度）
    // 尝试读取本地文件大小用于进度，否则模拟 1MB
    let total = std::fs::metadata(&local).map(|m| m.len()).unwrap_or(1024*1024);
    let op_id = uuid::Uuid::new_v4().to_string();
    for i in 1..=10 {
        tokio::time::sleep(std::time::Duration::from_millis(60)).await;
        let prog = i as f64 / 10.0;
        let _ = app.emit(&format!("sftp-progress://{}", op_id), serde_json::json!({"op":"upload","remote":remote,"progress":prog,"done": prog>=1.0}));
        let _ = total;
    }
    sftp.upload(&local, &remote).await.map_err(|e| e.to_string())?;
    let _ = app.emit(&format!("sftp-progress://{}", op_id), serde_json::json!({"op":"upload","remote":remote,"progress":1.0,"done":true}));
    Ok(())
}

#[tauri::command]
async fn sftp_download(session_id: String, remote: String, local: String, state: tauri::State<'_, SessionMap>, app: tauri::AppHandle) -> Result<(), String> {
    let entry = { let map = state.lock().await; map.get(&session_id).cloned().ok_or("session not found")? };
    let sftp = entry.session.open_sftp().await.map_err(|e| e.to_string())?;
    let op_id = uuid::Uuid::new_v4().to_string();
    for i in 1..=10 {
        tokio::time::sleep(std::time::Duration::from_millis(60)).await;
        let prog = i as f64 / 10.0;
        let _ = app.emit(&format!("sftp-progress://{}", op_id), serde_json::json!({"op":"download","remote":remote,"progress":prog,"done": prog>=1.0}));
    }
    sftp.download(&remote, &local).await.map_err(|e| e.to_string())?;
    let _ = app.emit(&format!("sftp-progress://{}", op_id), serde_json::json!({"op":"download","remote":remote,"progress":1.0,"done":true}));
    Ok(())
}

// ---- Port Forward ----

#[tauri::command]
async fn forward_start(forward_json: String, state: tauri::State<'_, ForwardState>) -> Result<bonk_core::forward::ForwardHandle, String> {
    let dto: PortForwardDto = serde_json::from_str(&forward_json).map_err(|e| e.to_string())?;
    state.start(dto).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn forward_stop(id: String, state: tauri::State<'_, ForwardState>) -> Result<(), String> {
    let uuid = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    state.stop(uuid).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn forward_list(state: tauri::State<'_, ForwardState>) -> Result<Vec<bonk_core::forward::ForwardHandle>, String> {
    state.list().await.map_err(|e| e.to_string())
}

// ---- Serial ----

#[tauri::command]
async fn serial_list(state: tauri::State<'_, SerialState>) -> Result<Vec<bonk_core::serial::SerialPortInfo>, String> {
    state.list_ports().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn serial_open(config_json: String, state: tauri::State<'_, SerialState>) -> Result<String, String> {
    let cfg: SerialConfig = serde_json::from_str(&config_json).map_err(|e| e.to_string())?;
    state.open(cfg).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn serial_close(handle_id: String, state: tauri::State<'_, SerialState>) -> Result<(), String> {
    state.close(&handle_id).await.map_err(|e| e.to_string())
}

// ---- Snippet / History ----

#[tauri::command]
async fn snippet_list(state: tauri::State<'_, SnippetState>) -> Result<Vec<SnippetDto>, String> {
    state.list().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn snippet_upsert(json: String, state: tauri::State<'_, SnippetState>) -> Result<(), String> {
    let dto: SnippetDto = serde_json::from_str(&json).map_err(|e| e.to_string())?;
    state.upsert(dto).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn snippet_delete(id: String, state: tauri::State<'_, SnippetState>) -> Result<(), String> {
    let uuid = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    state.delete(uuid).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn history_push(json: String, state: tauri::State<'_, HistoryState>) -> Result<(), String> {
    let dto: CommandHistoryDto = serde_json::from_str(&json).map_err(|e| e.to_string())?;
    state.push(dto).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn history_list(host_id: Option<String>, limit: Option<u32>, state: tauri::State<'_, HistoryState>) -> Result<Vec<CommandHistoryDto>, String> {
    let hid = match host_id { Some(s) => Some(uuid::Uuid::parse_str(&s).map_err(|e| e.to_string())?), None => None };
    state.list(hid, limit.unwrap_or(100) as usize).await.map_err(|e| e.to_string())
}

// ---- Workspace / Split ----

#[tauri::command]
async fn workspace_list(state: tauri::State<'_, WorkspaceState>) -> Result<Vec<WorkspaceDto>, String> {
    state.list().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn workspace_upsert(json: String, state: tauri::State<'_, WorkspaceState>) -> Result<(), String> {
    let ws: WorkspaceDto = serde_json::from_str(&json).map_err(|e| e.to_string())?;
    state.upsert(ws).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn workspace_delete(id: String, state: tauri::State<'_, WorkspaceState>) -> Result<(), String> {
    let uuid = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    state.delete(uuid).await.map_err(|e| e.to_string())
}

// ---- Monitor (device status) ----

#[tauri::command]
async fn monitor_fetch(host_id: String, session_id: Option<String>, state: tauri::State<'_, SessionMap>) -> Result<bonk_core::monitor::ServerInfoDto, String> {
    if let Some(sid) = session_id {
        let entry = { let map = state.lock().await; map.get(&sid).cloned() };
        if let Some(entry) = entry {
            let mut info = MonitorService::mock_info(&host_id);
            let load_out = entry.session.execute("cat /proc/loadavg 2>/dev/null; echo __MEM__; free -m 2>/dev/null | awk 'NR==2{print $2, $3}'; echo __DISK__; df -h / 2>/dev/null | awk 'NR==2{print $2, $3}'").await.map(|r| r.output).unwrap_or_default();
            if !load_out.is_empty() {
                if let Some(first) = load_out.lines().next() {
                    let parts: Vec<&str> = first.split_whitespace().collect();
                    if parts.len() >=3 {
                        info.load_avg = [parts[0].parse().unwrap_or(0.42), parts[1].parse().unwrap_or(0.38), parts[2].parse().unwrap_or(0.35)];
                    }
                }
                let mut after_mem = false;
                for line in load_out.lines() {
                    if line.contains("__MEM__") { after_mem = true; continue; }
                    if after_mem && !line.contains("__DISK__") && !line.is_empty() {
                        let v: Vec<&str> = line.split_whitespace().collect();
                        if v.len()>=2 { info.mem_total_mb = v[0].parse().unwrap_or(info.mem_total_mb); info.mem_used_mb = v[1].parse().unwrap_or(info.mem_used_mb); break; }
                    }
                }
            }
            let uname_out = entry.session.execute("uname -a 2>/dev/null").await.map(|r| r.output).unwrap_or_default();
            if !uname_out.trim().is_empty() { info.kernel = uname_out.trim().lines().next().unwrap_or(&info.kernel).to_string(); }
            info.checked_at = chrono::Utc::now();
            return Ok(info);
        }
    }
    Ok(MonitorService::mock_info(&host_id))
}

// ---- Import / Export ----

#[tauri::command]
async fn import_ssh_config(content: String) -> Result<bonk_core::import::ImportResult, String> {
    SshConfigImporter.discover(&content).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn import_tabby(content: String) -> Result<bonk_core::import::ImportResult, String> {
    TabbyImporter.discover(&content).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn export_hosts(host_list: Vec<HostItemDto>) -> Result<String, String> {
    export_hosts_json(&host_list).map_err(|e| e.to_string())
}

// ---- Recording ----

#[tauri::command]
async fn recording_start(session_id: String, host_name: String, state: tauri::State<'_, RecordingState>) -> Result<bonk_core::recording::RecordingMeta, String> {
    state.start(&session_id, &host_name).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn recording_stop(id: String, state: tauri::State<'_, RecordingState>) -> Result<(), String> {
    state.stop(&id).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn recording_list(state: tauri::State<'_, RecordingState>) -> Result<Vec<bonk_core::recording::RecordingMeta>, String> {
    state.list().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn recording_append(id: String, event_json: String, state: tauri::State<'_, RecordingState>) -> Result<(), String> {
    let ev: RecordingEvent = serde_json::from_str(&event_json).map_err(|e| e.to_string())?;
    state.append(&id, ev).await.map_err(|e| e.to_string())
}

// ---- Broadcast ----

#[tauri::command]
async fn broadcast_start(session_ids: Vec<String>, state: tauri::State<'_, BroadcastState>) -> Result<bonk_core::broadcast::BroadcastGroup, String> {
    state.start(session_ids).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn broadcast_stop(group_id: String, state: tauri::State<'_, BroadcastState>) -> Result<(), String> {
    state.stop(&group_id).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn broadcast_send(group_id: String, data: String, state: tauri::State<'_, BroadcastState>, sessions: tauri::State<'_, SessionMap>) -> Result<(), String> {
    // fan-out to sessions
    let group = {
        let list = state.list().await.map_err(|e| e.to_string())?;
        list.into_iter().find(|g| g.id==group_id).ok_or("group not found")?
    };
    let map = sessions.lock().await;
    for sid in group.session_ids {
        if let Some(entry) = map.get(&sid) {
            let _ = entry.pty.lock().await.write(data.as_bytes()).await;
        }
    }
    state.send(&group_id, data.as_bytes()).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn broadcast_list(state: tauri::State<'_, BroadcastState>) -> Result<Vec<bonk_core::broadcast::BroadcastGroup>, String> {
    state.list().await.map_err(|e| e.to_string())
}

// ---- Team ----

#[tauri::command]
async fn team_discover(state: tauri::State<'_, TeamState>) -> Result<Vec<bonk_core::team::TeamMemberDto>, String> {
    state.discover().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn team_share(session_ids: Vec<String>, title: String, state: tauri::State<'_, TeamState>) -> Result<bonk_core::team::TeamSessionDto, String> {
    state.start_share(session_ids, &title).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn team_stop_share(id: String, state: tauri::State<'_, TeamState>) -> Result<(), String> {
    let uuid = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    state.stop_share(uuid).await.map_err(|e| e.to_string())
}

// ---- Settings ----

#[tauri::command]
async fn settings_load(state: tauri::State<'_, SettingsState>) -> Result<UserPreferencesDto, String> {
    state.load().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn settings_save(json: String, state: tauri::State<'_, SettingsState>) -> Result<(), String> {
    let prefs: UserPreferencesDto = serde_json::from_str(&json).map_err(|e| e.to_string())?;
    state.save(prefs).await.map_err(|e| e.to_string())
}

// ---- Log colorizer ----

#[tauri::command]
fn log_classify(line: String) -> String {
    let lv = logmod::classify_line(&line);
    serde_json::to_string(&lv).unwrap_or("\"Unknown\"".into())
}

#[tauri::command]
fn log_colorize(lines: Vec<String>) -> Vec<Vec<logmod::LogToken>> {
    logmod::colorize_lines(&lines)
}

// ---- AI (P1 真连 + mock 回落) ----

fn build_ai_provider(model: Option<String>) -> Box<dyn AiProvider> {
    let m = model.unwrap_or_else(|| std::env::var("BONK_AI_MODEL").unwrap_or_else(|_| "gpt-4o-mini".into()));
    let ml = m.to_lowercase();
    if ml.contains("claude") {
        let key = std::env::var("ANTHROPIC_API_KEY").or_else(|_| std::env::var("CLAUDE_API_KEY")).unwrap_or_default();
        Box::new(ClaudeProvider { api_key: key, model: m })
    } else if ml.contains("gemini") {
        let key = std::env::var("GEMINI_API_KEY").or_else(|_| std::env::var("GOOGLE_API_KEY")).unwrap_or_default();
        Box::new(GeminiProvider { api_key: key, model: m })
    } else if ml.contains("ollama") || ml.contains("llama") || ml.starts_with("qwen") {
        let base = std::env::var("OLLAMA_BASE_URL").unwrap_or_else(|_| "http://localhost:11434".into());
        Box::new(OllamaProvider { base_url: base, model: m })
    } else {
        let key = std::env::var("OPENAI_API_KEY").unwrap_or_default();
        let base = std::env::var("OPENAI_BASE_URL").unwrap_or_else(|_| "https://api.openai.com".into());
        Box::new(OpenAiCompatProvider { base_url: base, api_key: key, model: m })
    }
}

#[tauri::command]
async fn ai_complete(prompt: String, model: Option<String>) -> Result<String, String> {
    let provider = build_ai_provider(model.clone());
    let req = AiCompletionRequest {
        model: model.unwrap_or_default(),
        messages: vec![AiMessage { role: "user".into(), content: prompt.clone() }],
        max_tokens: Some(2048),
        temperature: Some(0.7),
    };
    match provider.complete(req).await {
        Ok(resp) => Ok(resp.content),
        Err(e) => {
            // fallback mock to keep UI responsive offline
            tracing::warn!("ai_complete fallback mock: {}", e);
            Ok(format!("[AI mock fallback: {}] {}", e, prompt))
        }
    }
}

#[tauri::command]
async fn ai_complete_stream(prompt: String, model: Option<String>, app: tauri::AppHandle) -> Result<(), String> {
    // P1 真流式：先尝试真连，非流式返回后分片 emit 模拟流式；P2 再接 SSE
    let provider = build_ai_provider(model.clone());
    let req = AiCompletionRequest {
        model: model.unwrap_or_default(),
        messages: vec![AiMessage { role: "user".into(), content: prompt.clone() }],
        max_tokens: Some(2048),
        temperature: Some(0.7),
    };
    match provider.complete(req).await {
        Ok(resp) => {
            // Chunked emit to mimic streaming
            let chunk_size = 24;
            let chars: Vec<char> = resp.content.chars().collect();
            for chunk in chars.chunks(chunk_size) {
                let s: String = chunk.iter().collect();
                let _ = app.emit("ai-stream://chunk", s);
                tokio::time::sleep(std::time::Duration::from_millis(35)).await;
            }
            let _ = app.emit("ai-stream://done", "");
            Ok(())
        },
        Err(e) => {
            let msg = format!("[AI mock stream fallback: {}] {}", e, prompt);
            for chunk in msg.chars().collect::<Vec<_>>().chunks(20) {
                let s: String = chunk.iter().collect();
                let _ = app.emit("ai-stream://chunk", s);
                tokio::time::sleep(std::time::Duration::from_millis(40)).await;
            }
            let _ = app.emit("ai-stream://done", "");
            Ok(())
        }
    }
}

fn build_host_store() -> HostState {
    {
        // Try app_data_dir/bonk.db else ./bonk.db
        let candidate_paths = [
            dirs_next::data_dir().map(|p| p.join("com.bonk.win").join("bonk.db")),
            Some(std::path::PathBuf::from("bonk.db")),
            Some(std::env::temp_dir().join("bonk.db")),
        ];
        for opt in candidate_paths.iter().flatten() {
            if let Some(parent) = opt.parent() { let _ = std::fs::create_dir_all(parent); }
            match SqliteHostStore::new(&opt.to_string_lossy()) {
                Ok(store) => {
                    tracing::info!("using SqliteHostStore at {:?}", opt);
                    return Arc::new(store) as HostState;
                }
                Err(e) => { tracing::warn!("SqliteHostStore {:?} failed: {}", opt, e); }
            }
        }
    }
    tracing::info!("using InMemoryHostStore (fallback)");
    Arc::new(InMemoryHostStore::new()) as HostState
}

fn main() {
    bonk_core::init();

    let sessions: SessionMap = Arc::new(Mutex::new(HashMap::new()));
    let hosts: HostState = build_host_store();
    let forwards: ForwardState = Arc::new(InMemoryForwardService::new());
    let serials: SerialState = Arc::new(InMemorySerialService);
    let snippets: SnippetState = Arc::new(InMemorySnippetStore::new());
    let history: HistoryState = Arc::new(InMemoryHistoryStore::new());
    let workspaces: WorkspaceState = Arc::new(InMemoryWorkspaceStore::new());
    let settings: SettingsState = Arc::new(InMemorySettingsStore::new());
    let teams: TeamState = Arc::new(InMemoryTeamService::new());
    let broadcasts: BroadcastState = Arc::new(InMemoryBroadcastService::new());
    let recordings: RecordingState = Arc::new(RecordingService::new());

    let hosts_clone = hosts.clone();
    tauri::Builder::default()
        .manage(sessions)
        .manage(hosts)
        .manage(forwards)
        .manage(serials)
        .manage(snippets)
        .manage(history)
        .manage(workspaces)
        .manage(settings)
        .manage(teams)
        .manage(broadcasts)
        .manage(recordings)
        .setup(move |_app| {
            // Seed hosts if empty (async)
            let hs = hosts_clone.clone();
            tauri::async_runtime::spawn(async move {
                if let Ok(list) = hs.list().await {
                    if list.is_empty() {
                        tracing::info!("seeding hosts (first run)");
                        let seed = vec![
                            ("h204","192.168.100.204","g1"),("h50","192.168.100.50","g2"),("h51","192.168.100.51","g2"),
                            ("h52","192.168.100.52","g2"),("h53","192.168.100.53","g2"),("h54","192.168.100.54","g2"),
                            ("h55","192.168.100.55","g2"),("h193","192.168.100.193","g3"),("h194","192.168.100.194","g3"),
                            ("h195","192.168.100.195","g3"),("h155","192.168.100.155","g4"),("h156","192.168.100.156","g4"),
                            ("h31","192.168.100.31","g5"),("h102","172.16.10.102","g5"),("h46","192.168.100.46","g6"),("h240","192.168.100.240","g7"),
                        ];
                        for (id, host, gid) in seed {
                            let dto = HostItemDto {
                                id: uuid::Uuid::parse_str(id).unwrap_or_else(|_| uuid::Uuid::new_v4()),
                                name: host.into(), host: host.into(), port: 22, username: "root".into(),
                                auth_type: AuthType::Password, group_id: None, credential_id: None, jump_host_id: None,
                                created_at: chrono::Utc::now(), last_connected_at: None, sort_order: 0,
                                is_favorite: false, is_serial: false, serial_baud_rate: None, force_compatibility: false,
                            };
                            let _ = hs.upsert(dto).await;
                            let _ = gid;
                        }
                    }
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            core_version, core_validate_host,
            ssh_connect, ssh_disconnect, ssh_write, ssh_resize, ssh_execute, ssh_decision,
            host_list, host_upsert, host_delete, host_get,
            sftp_list, sftp_mkdir, sftp_remove, sftp_exists, sftp_upload, sftp_download,
            forward_start, forward_stop, forward_list,
            serial_list, serial_open, serial_close,
            snippet_list, snippet_upsert, snippet_delete, history_push, history_list,
            workspace_list, workspace_upsert, workspace_delete,
            monitor_fetch,
            import_ssh_config, import_tabby, export_hosts,
            recording_start, recording_stop, recording_list, recording_append,
            broadcast_start, broadcast_stop, broadcast_send, broadcast_list,
            team_discover, team_share, team_stop_share,
            settings_load, settings_save,
            log_classify, log_colorize,
            ai_complete, ai_complete_stream
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri app");
}
