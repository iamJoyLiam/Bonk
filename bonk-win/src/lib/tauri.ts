import { invoke } from "@tauri-apps/api/core";
import type {
  HostItem, SftpEntry, PortForwardDto, ForwardHandle, SerialPortInfo, SerialConfig,
  SnippetDto, CommandHistoryDto, WorkspaceDto, ServerInfoDto, ImportResult,
  RecordingMeta, RecordingEvent, BroadcastGroup, TeamMemberDto, TeamSessionDto,
  UserPreferencesDto, LogToken
} from "./types";

// All commands defined in bonk-win/src-tauri/src/main.rs
// Rust core linked directly - invoke = FFI inside same process.

export interface ConnectArgs {
  host: string;
  port: number;
  username: string;
  authType: string;
  secret?: string;
  jumpHosts?: { host: string; port: number; username: string; authType?: string; secret?: string }[];
}

export interface JumpArgs { host: string; port: number; username: string; authType?: string; secret?: string; }

// ---- Core ----
export async function coreVersion(): Promise<string> { return invoke<string>("core_version"); }
export async function coreValidateHost(json: string): Promise<boolean> { return invoke<boolean>("core_validate_host", { json }); }

// ---- SSH ----
export async function sshConnect(args: ConnectArgs): Promise<string> { return invoke<string>("ssh_connect", { args }); }
export async function sshDisconnect(sessionId: string): Promise<void> { return invoke("ssh_disconnect", { sessionId }); }
export async function sshWrite(sessionId: string, data: string): Promise<void> { return invoke("ssh_write", { sessionId, data }); }
export async function sshResize(sessionId: string, cols: number, rows: number): Promise<void> { return invoke("ssh_resize", { sessionId, cols, rows }); }
export async function sshExecute(sessionId: string, command: string): Promise<string> { return invoke<string>("ssh_execute", { sessionId, command }); }
export async function sshDecision(args: ConnectArgs): Promise<string> { return invoke<string>("ssh_decision", { args }); }

// ---- Host / Group ----
export async function hostList(): Promise<HostItem[]> { return invoke<HostItem[]>("host_list"); }
export async function hostUpsert(host: HostItem): Promise<void> { return invoke("host_upsert", { hostJson: JSON.stringify(host) }); }
export async function hostDelete(id: string): Promise<void> { return invoke("host_delete", { id }); }
export async function hostGet(id: string): Promise<HostItem | null> { return invoke<HostItem | null>("host_get", { id }); }

// ---- SFTP ----
export async function sftpList(sessionId: string, path: string): Promise<SftpEntry[]> { return invoke<SftpEntry[]>("sftp_list", { sessionId, path }); }
export async function sftpMkdir(sessionId: string, path: string): Promise<void> { return invoke("sftp_mkdir", { sessionId, path }); }
export async function sftpRemove(sessionId: string, path: string, isDir: boolean): Promise<void> { return invoke("sftp_remove", { sessionId, path, isDir }); }
export async function sftpExists(sessionId: string, path: string): Promise<boolean> { return invoke<boolean>("sftp_exists", { sessionId, path }); }
export async function sftpUpload(sessionId: string, local: string, remote: string): Promise<void> { return invoke("sftp_upload", { sessionId, local, remote }); }
export async function sftpDownload(sessionId: string, remote: string, local: string): Promise<void> { return invoke("sftp_download", { sessionId, remote, local }); }

// ---- Forward ----
export async function forwardStart(dto: PortForwardDto): Promise<ForwardHandle> { return invoke<ForwardHandle>("forward_start", { forwardJson: JSON.stringify(dto) }); }
export async function forwardStop(id: string): Promise<void> { return invoke("forward_stop", { id }); }
export async function forwardList(): Promise<ForwardHandle[]> { return invoke<ForwardHandle[]>("forward_list"); }

// ---- Serial ----
export async function serialList(): Promise<SerialPortInfo[]> { return invoke<SerialPortInfo[]>("serial_list"); }
export async function serialOpen(cfg: SerialConfig): Promise<string> { return invoke<string>("serial_open", { configJson: JSON.stringify(cfg) }); }
export async function serialClose(handleId: string): Promise<void> { return invoke("serial_close", { handleId }); }

// ---- Snippet / History ----
export async function snippetList(): Promise<SnippetDto[]> { return invoke<SnippetDto[]>("snippet_list"); }
export async function snippetUpsert(dto: SnippetDto): Promise<void> { return invoke("snippet_upsert", { json: JSON.stringify(dto) }); }
export async function snippetDelete(id: string): Promise<void> { return invoke("snippet_delete", { id }); }
export async function historyPush(dto: CommandHistoryDto): Promise<void> { return invoke("history_push", { json: JSON.stringify(dto) }); }
export async function historyList(hostId?: string, limit?: number): Promise<CommandHistoryDto[]> { return invoke<CommandHistoryDto[]>("history_list", { hostId, limit }); }

// ---- Workspace / Split ----
export async function workspaceList(): Promise<WorkspaceDto[]> { return invoke<WorkspaceDto[]>("workspace_list"); }
export async function workspaceUpsert(ws: WorkspaceDto): Promise<void> { return invoke("workspace_upsert", { json: JSON.stringify(ws) }); }
export async function workspaceDelete(id: string): Promise<void> { return invoke("workspace_delete", { id }); }

// ---- Monitor ----
export async function monitorFetch(hostId: string, sessionId?: string): Promise<ServerInfoDto> { return invoke<ServerInfoDto>("monitor_fetch", { hostId, sessionId }); }

// ---- Import / Export ----
export async function importSshConfig(content: string): Promise<ImportResult> { return invoke<ImportResult>("import_ssh_config", { content }); }
export async function importTabby(content: string): Promise<ImportResult> { return invoke<ImportResult>("import_tabby", { content }); }
export async function exportHosts(hosts: HostItem[]): Promise<string> { return invoke<string>("export_hosts", { hostList: hosts }); }

// ---- Recording ----
export async function recordingStart(sessionId: string, hostName: string): Promise<RecordingMeta> { return invoke<RecordingMeta>("recording_start", { sessionId, hostName }); }
export async function recordingStop(id: string): Promise<void> { return invoke("recording_stop", { id }); }
export async function recordingList(): Promise<RecordingMeta[]> { return invoke<RecordingMeta[]>("recording_list"); }
export async function recordingAppend(id: string, event: RecordingEvent): Promise<void> { return invoke("recording_append", { id, eventJson: JSON.stringify(event) }); }

// ---- Broadcast ----
export async function broadcastStart(sessionIds: string[]): Promise<BroadcastGroup> { return invoke<BroadcastGroup>("broadcast_start", { sessionIds }); }
export async function broadcastStop(groupId: string): Promise<void> { return invoke("broadcast_stop", { groupId }); }
export async function broadcastSend(groupId: string, data: string): Promise<void> { return invoke("broadcast_send", { groupId, data }); }
export async function broadcastList(): Promise<BroadcastGroup[]> { return invoke<BroadcastGroup[]>("broadcast_list"); }

// ---- Team ----
export async function teamDiscover(): Promise<TeamMemberDto[]> { return invoke<TeamMemberDto[]>("team_discover"); }
export async function teamShare(sessionIds: string[], title: string): Promise<TeamSessionDto> { return invoke<TeamSessionDto>("team_share", { sessionIds, title }); }
export async function teamStopShare(id: string): Promise<void> { return invoke("team_stop_share", { id }); }

// ---- Settings ----
export async function settingsLoad(): Promise<UserPreferencesDto> { return invoke<UserPreferencesDto>("settings_load"); }
export async function settingsSave(prefs: UserPreferencesDto): Promise<void> { return invoke("settings_save", { json: JSON.stringify(prefs) }); }

// ---- Log ----
export async function logClassify(line: string): Promise<string> { return invoke<string>("log_classify", { line }); }
export async function logColorize(lines: string[]): Promise<LogToken[][]> { return invoke<LogToken[][]>("log_colorize", { lines }); }

// ---- AI ----
export async function aiComplete(prompt: string, model?: string): Promise<string> { return invoke<string>("ai_complete", { prompt, model }); }
export async function aiCompleteStream(prompt: string, model?: string): Promise<void> { return invoke("ai_complete_stream", { prompt, model }); }

// Streaming: pty-data://<sessionId> and ai-stream://chunk events via listen()
