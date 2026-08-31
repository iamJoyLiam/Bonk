// Mirrors bonk-core/src/models/* + all P0 modules
// Keep serde(rename_all="camelCase") alignment

export type AuthType = "password" | "privateKey" | "certificate" | "secureEnclave";

export interface HostItem {
  id: string;
  name: string;
  host: string;
  port: number;
  username: string;
  authType: AuthType;
  groupId?: string | null;
  credentialId?: string | null;
  jumpHostId?: string | null;
  createdAt?: string;
  lastConnectedAt?: string | null;
  sortOrder?: number;
  isFavorite?: boolean;
  isSerial?: boolean;
  serialBaudRate?: number | null;
  forceCompatibility?: boolean;
}

export interface HostGroup {
  id: string;
  name: string;
  color?: string;
}

export interface JumpHostDto {
  host: string;
  port: number;
  username: string;
  authType: AuthType;
  secret?: string;
}

export interface SftpEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  size: number;
  modified?: string | null;
  permissions?: string | null;
}

export interface TerminalTab {
  id: string;
  host: HostItem;
  title: string;
  sessionId?: string | null; // Tauri session id after ssh_connect
  isActive?: boolean;
}

// ---- Forward ----

export type ForwardType = "local" | "remote" | "dynamic";
export interface PortForwardDto {
  id: string;
  hostId: string;
  forwardType: ForwardType;
  localHost: string;
  localPort: number;
  remoteHost: string;
  remotePort: number;
  enabled: boolean;
}
export interface ForwardHandle {
  id: string;
  forward: PortForwardDto;
  state: "active" | "stopped" | "error";
}

// ---- Serial ----

export interface SerialPortInfo {
  name: string;
  displayName: string;
  manufacturer?: string | null;
  product?: string | null;
}
export interface SerialConfig {
  port: string;
  baudRate: number;
  dataBits?: number;
  stopBits?: number;
  parity?: string;
  flowControl?: string;
}

// ---- Snippet / History ----

export interface SnippetDto {
  id: string;
  name: string;
  content: string;
  description?: string | null;
  tags: string[];
  createdAt: string;
}
export interface CommandHistoryDto {
  id: string;
  hostId?: string | null;
  command: string;
  executedAt: string;
  exitCode?: number | null;
}

// ---- Workspace / Split ----

export type SplitDirection = "horizontal" | "vertical";
export interface LayoutNodeDto {
  id: string;
  direction?: SplitDirection | null;
  ratio?: number | null;
  children: LayoutNodeDto[];
  tabId?: string | null;
}
export interface WorkspaceDto {
  id: string;
  name: string;
  root: LayoutNodeDto;
  createdAt: string;
  updatedAt: string;
}

// ---- Monitor ----

export interface ServerInfoDto {
  hostId: string;
  hostname: string;
  os: string;
  kernel: string;
  uptimeSecs: number;
  cpuUsagePercent: number;
  memTotalMb: number;
  memUsedMb: number;
  diskTotalGb: number;
  diskUsedGb: number;
  loadAvg: [number, number, number];
  netRxBytes: number;
  netTxBytes: number;
  checkedAt: string;
}

// ---- Import / Export ----

export interface ImportResult {
  source: string;
  count: number;
  hosts: HostItem[];
  warnings: string[];
}

// ---- Recording ----

export interface RecordingMeta {
  id: string;
  sessionId: string;
  hostName: string;
  startedAt: string;
  durationSecs?: number | null;
  filePath: string;
}
export interface RecordingEvent {
  time: number;
  data: string;
  eventType: string;
}

// ---- Broadcast ----

export interface BroadcastGroup {
  id: string;
  sessionIds: string[];
  enabled: boolean;
}

// ---- Team ----

export interface TeamMemberDto {
  id: string;
  name: string;
  host: string;
  online: boolean;
}
export interface TeamSessionDto {
  id: string;
  ownerId: string;
  title: string;
  sharedSessionIds: string[];
}

// ---- Settings ----

export interface UserPreferencesDto {
  theme: string;
  fontFamily: string;
  fontSize: number;
  keepAliveSecs: number;
  reconnectEnabled: boolean;
  reconnectMaxRetries: number;
  quakeHotkey: string;
  logColorizerEnabled: boolean;
  aiEnabled: boolean;
  language: string;
}

// ---- Log ----

export type LogLevel = "trace" | "debug" | "info" | "warn" | "error" | "fatal" | "unknown";
export interface LogToken {
  level: LogLevel;
  text: string;
  color: string;
  start: number;
  end: number;
}
export interface LogProfileDto {
  id: string;
  name: string;
  pattern: string;
  level: LogLevel;
  color: string;
}

// ---- SSH Decision ----

export type SshBackendType = "native" | "compatibility";
export type SshBackendReason = "modern" | "kexMismatch" | "hostKeyMismatch" | "cipherMismatch" | "noKbdInteractive" | "jumpHost" | "forcedCompatibility";
export type SshDecision = "native" | { compatibility: { reason: SshBackendReason } } | "nativeWithFallback";

// ---- Shared ----

export interface SshDecisionResult {
  decision: string; // raw json from Rust
}
