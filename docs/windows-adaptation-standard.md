# Bonk Windows 适配标准化方案 v1.0

> 目标：**100% 功能平移，UI 后期再精。**  
> 原则：**Rust 核是唯一真理（Single Source of Truth），Mac/Win 只是壳。**  
> 状态：草案定稿 · 2026-08-31 · 替代所有口头约定  
> 关联：`AGENTS.md` `ssh-vnext-architecture.md v3.1` `FEATURE_ROADMAP.md` `README.bonk-core.md`

---

## 1. 总则（必须标准化）

### 1.1 一句话架构

```
Bonk/         → macOS Shell (SwiftUI + AppKit) 不动，保持发版
bonk-core/    → Rust 共享核：所有业务逻辑的唯一实现
bonk-mac-ffi/ → Swift FFI 桥（Mac 逐步把逻辑下沉到 Rust）
bonk-win/     → Windows Shell (Tauri v2 + React + xterm.js + Zustand)
              → 直接依赖 bonk-core（同一进程，零 IPC 额外开销）
```

> **铁律 1**：任何新能力先在 `bonk-core` 用 Trait 实现，两端壳只做 UI/系统集成，不重复写业务。  
> **铁律 2**：DTO 用 `serde JSON` 过 FFI/Invoke，比 C struct 稳定，跨语言不漂移。  
> **铁律 3**：mock 优先，可 `cargo check` / `vite dev` 不阻塞并行。

### 1.2 分层标准（3 层对外，6 层对内）

```
UI 层 (React / SwiftUI) ─┐
                         ├─ 纯展示，不含业务
Shell 层 (Tauri / AppKit)┘

Domain 层 (bonk-core/models)     → 纯 DTO (HostItemDto, SftpFileEntry, TerminalSize)
Service 层 (bonk-core/ssh| sftp| pty| storage| keychain| ai) → Trait 抽象
Engine 层 (russh / portable-pty / keyring / rusqlite / reqwest) → 平台适配
Runtime (Win32 ConPTY / Credential Manager / SQLite)          → OS 能力
```

**上层只依赖 Trait，不知底层是谁。**

### 1.3 标准化交付物

| 交付物 | 路径 | 准入条件 |
|--------|------|----------|
| Rust 核编译通过 | `bonk-core/cargo check && cargo test` | 零 warning |
| Mock 可跑 | `bonk-win/npm run dev` xterm 可打字 | 无需 Rust 环境 |
| 真连可跑 | `bonk-win/npm run tauri:dev` `ssh_connect` 走 russh | 密码 auth 打通 |
| Mac FFI 不回归 | `Bonk.xcodeproj` 引入 `bonk-mac-ffi` 可切 `useRustCore` | 双轨可用 |

---

## 2. 现状进度审计（截至 2026-08-31）

### 2.1 bonk-core

| 模块 | 文件 | 完成度 | 说明 |
|------|------|--------|------|
| `models` | `host.rs` `mod.rs` | **85%** | HostItemDto/SshConnectionConfig/AuthType/TerminalSize/SftpFileEntry 已齐；缺 `HostGroupDto/CredentialDto` 持久化扩展、JumpChain 完整 DTO |
| `ssh` | `mod.rs` `session.rs` `config.rs` | **60%** | Trait(SshSession/PtyChannel/SftpChannel) 已定，`RusshSession` 密码+mock 链路打通，PTY streaming 已通；缺：私钥/证书/auth none 完整、SFTP 真连(reussh-sftp)、跳板、Forward、ControlMaster、KeepAlive、Reconnect |
| `storage` | `mod.rs` | **40%** | `HostStore` trait + InMemory；`SqliteHostStore` 仅 JSON blob，最小可用；缺：Group/Credential/Layout/Preferences/AI对话的完整表、迁移、事务 |
| `keychain` | `mod.rs` | **55%** | `CredentialStore` trait + keyring/InMemory；缺：私钥 passphrase、key id 命名与 Mac KeychainHelper 对齐的完整 E2E |
| `pty` | `mod.rs` | **30%** | 仅 `LocalPty` (portable-pty spawn shell)，用于本地预览；缺：把 `RusshPtyChannel` 抽到 `pty/ssh_pty.rs` 并与 `TerminalEngine` 的 watermark/防丢策略对齐 |
| `sftp` | `mod.rs` | **25%** | 仅 path normalize + sort；缺：与 `ssh::SftpChannel` 绑定的真实 SFTP engine（russh + 多路复用 + 并行传输） |
| `ai` | `mod.rs` | **15%** | Mock `AiProvider`；缺：OpenAI-compatible/Claude/Gemini/Ollama 4 家的 `reqwest` 真实现、流式、tool-call 循环、TerminalContext |
| `ffi` | `mod.rs` | **20%** | `bonk_core_version/validate_host_json/free_string` 三个 C ABI；缺：`bonk_core_ssh_*` 的 tokio Runtime + callback 完整 FFI（供 Mac 调用） |

### 2.2 bonk-win (Tauri)

| 模块 | 完成度 | 说明 |
|------|--------|------|
| `src-tauri/main.rs` | **45%** | `ssh_connect` 已开 PTY 并 `emit pty-data://`，`ssh_disconnect` 正常；`ssh_write/resize` 仅 log TODO（未持有 PtyChannel 句柄） |
| `src/components/TerminalView.tsx` | **60%** | xterm.js + FitAddon + WebLinks + mock/真连双路径；缺：真连下 `onData -> ssh_write` 串联、`onResize -> ssh_resize`、重连、Zmodem 钩子 |
| `src/lib/store.ts` | **70%** | Zustand mock 16 台主机 + 7 分组 1:1 复刻 Mac 截图；缺：接 `invoke(list_hosts)` 真数据、Tab 与 SessionId 绑定 |
| `src/lib/tauri.ts` `types.ts` | **65%** | 已封装 `coreVersion/sshConnect/Disconnect/Write/Resize`；缺：`list_hosts/upsert/delete/sftp_* /port_forward/ai_*` 整套 invoke |
| `Sidebar/TabBar/Toolbar/TitleBar` | **50%** | 结构齐，样式 1:1 复刻 Mac；缺：搜索、右键菜单、拖拽、SFTP 面板、AI 侧边栏 |

### 2.3 总体结论

> **壳已搭好，核已立 Trait，链路已打通“hello world”，但大量 Mac 能力尚未下沉到 Rust。**  
> 下一步不是重搭架子，而是**按表逐项把 Mac Swift 实现翻译成 Rust Trait 实现**，保证“Win 有 = Mac 有”。

---

## 3. 核心：SSH 方案转变复用总表（标准化必看）

> 本表是 **Windows 适配是否“标准化”** 的判定依据。所有 SSH 相关决策按此表执行，禁止各模块自行发明。

### 3.1 SSH 总览：Mac → Win 引擎映射

| 能力 | Mac 现状 (Bonk Mac) | Windows 目标 (bonk-core) | 复用度 | 转变方案 | 优先级 |
|------|---------------------|--------------------------|--------|----------|--------|
| **统一抽象** | `SSHSession` protocol + `NIO/NIOSSH/Citadel` + `OpenSSHBackend` + `SSHSessionCoordinator` | `bonk_core::ssh::SshSession/PtyChannel/SftpChannel + SshConnector` | **100% 复用 Trait** | 直接复用 `SSHDomainTypes.swift` 的 `Requirements/Capabilities/Decision` 模型，Rust 侧 1:1 镜像 `SshConnectionRequirements / SshBackendCapabilities / SshConnectionDecision` | P0 |
| **原生引擎** | Citadel(swift-nio-ssh 0.3.6) : 现代 KEX/curve25519、password/ed25519/SecureEnclave、PTY/Exec | `russh 0.45 + russh-keys + ring` : 纯 Rust、Win/Linux/mac 通用 | **Trait 复用，引擎替换** | Mac `NativeSSHSession` ↔ Win `RusshSession`，同属 `SshSession`，上层不感知 | P0 |
| **兼容引擎** | `OpenSSHBackend` 子进程 (`ssh -o …` + ControlMaster + Askpass) | **阶段一不引入** Win OpenSSH 子进程；**阶段二按需** `ssh2/libssh2` 或 `OpenSSH ssh.exe` 子进程（与 Mac 行为对齐） | **策略复用** | VNext `Compatibility` 概念保留，但 Win 早期用 `russh` 单引擎覆盖 95% 现代主机；legacy 再补子进程兜底 | P1 |
| **路由决策** | `SSHSessionCoordinator.resolve()` + `SSHFailureClassification` (仅 protocolCompatibility/backendCapability 允许切换) | Rust `SshConnector::connect()` 内置同款决策 + `CoreError::Ssh(classification)` | **100% 复用规则** | 把 `ssh-vnext-architecture.md §5` 的 6 条静态规则 + 1 次 fallback 原样搬到 Rust | P0 |
| **HostKey 校验** | `HostKeyValidator` + `PersistentHostKeyStore` (SwiftData `SSHBackendProfile`) | `host_key::Validator` + `SqliteHostStore(backend_profiles)` | **逻辑复用** | 指纹计算（SHA256）、首次信任/变更告警、TTL 7 天，原样移植 | P0 |

### 3.2 SSH 认证方式转变

| 认证 | Mac 实现 | Win 复用方案 | 复用度 | 关键转变点 |
|------|----------|--------------|--------|------------|
| Password | `SSHAuthMethod.password` → Citadel password / OpenSSH Askpass | `RusshSession::authenticate_password` | 直接复用 | secret 经 `CredentialStore::get(password_key(host_id))` 注入，内存 `#[serde(skip)]` 不落盘 |
| PrivateKey (Ed25519/ECDSA/RSA) | `SecureEnclaveSSHKey` + `OpenSSHBackend+Identity` (ssh-agent / IdentityFile) | `russh_keys::decode_secret_key(pem, passphrase)` → `authenticate_publickey` | Trait 复用，底层替换 | Mac 的 `SecureEnclave` 在 Win 降级为 `PrivateKey` (keyring 存 passphrase)，接口保持 `AuthType::SecureEnclave` 但路由到 privateKey |
| Certificate | 仅 OpenSSH (`ssh -i cert`) | `russh` 目前证书支持弱 → **P1 走 OpenSSH 子进程** 或 `ssh2` | 策略复用 | `requiresCertificate=true` → 直接 `compatibility` 分支，避免 russh 报 `no supported auth` |
| Keyboard-Interactive / MFA | 仅 OpenSSH | 同上 → `compatibility` | 策略复用 | _classifier 识别 `no supported authentication methods` 时归为 `backendCapability` 才允许切换 |
| Agent | OpenSSH `ssh-agent` | `russh` 暂不支持 agent → `compatibility` | 策略复用 | Win 上 `pageant` / `ssh-agent` 走子进程路径 |

### 3.3 SSH 连接特性转变

| 特性 | Mac | Win | 复用方案 |
|------|-----|-----|----------|
| **跳板 JumpHost** | `JumpHostService` + `SSHRoute{hops}` + ControlMaster 多段 | `SshConnectionConfig.jump_hosts: Vec<JumpHostDto>` → russh 链式 `connect(jump).channel_open_direct_tcpip(target)` | DTO 复用，Rust 侧递归建链，P0 先支持 1 跳，P1 支持 N 跳 |
| **KeepAlive** | `SSHKeepAlive` (ServerAliveInterval) | `tokio::time::interval(keepalive_secs)` → `handle.keepalive` / `channel.data` heartbeat | 参数 `keepalive_secs` 复用，P0 |
| **自动重连** | `ReconnectPolicy` + `PTTYSession` actor + `Network.framework` 监控 | Rust `ReconnectPolicy { max_retries, backoff }` + `tokio::net` + `NetworkChange` (Tauri event `network-status`) | 策略复用，P0 |
| **端口转发** | `PortForwardService` + `NativePortForward`/`OpenSSHForwardHandle` | `russh::Channel::open_direct_tcpip` (L) / `tcpip_forward` (R) / `channel_open_dynamic` (Socks) | Trait `ForwardChannel`，P1 |
| **SFTP** | `SFTPService` + `SFTPMultiTCPPool` + `SFTPParallelTransferEngine` + `SFTPCompression` | `russh-sftp` 或 `ssh2::Sftp` (二选一) + Rust 并行分片 (`tokio::io::copy` + 并发控制) | P0 保证单连接 SFTP `open_sftp → list/upload/download`，P1 再补并行/压缩 |
| **PTY 终端** | `PTYSession` + `TerminalEngine` (watermark 256K, coalescer, display tick) + SwiftTerm/Metal | `RusshPtyChannel` → Tauri `emit("pty-data://")` → xterm.js；本地备用 `portable-pty` ConPTY | 核心是把 Mac `TerminalEngine` 的 **watermark+coalescer+tick** 策略搬到 Rust 前端缓冲，P0 |
| **算法协商** | `SSHAlgorithmRequirements` → OpenSSH `-o KexAlgorithms=+…` | `russh::client::Config { preferred: … }` 按 `kex/hostKey/cipher/mac` 覆盖 | 配置 DTO 复用，P1 |
| **Zmodem** | `ZmodemHandler` (rz/sz 嗅探) | xterm.js 侧 `addon` 嗅探 `**\x18B0…` → 触发 `sftp upload/download` 对话框 | 嗅探逻辑复用 Rust，P2 |
| **SSH Config 导入** | `SSHConfigParser` + `SSHConfigWatcher` | Rust `ssh-config` crate 或自实现 parser，复用 `~/.ssh/config` 路径（Win `~\.ssh\config`） | 解析逻辑复用，P0 |
| **密钥生成** | `SSHKeyGenerator` (ed25519/ecdsa/rsa + Keychain) | `russh_keys` / `ssh-key` crate 生成 + `CredentialStore::set` | 算法复用，P0 |

### 3.4 SSH 错误分类（必须 100% 对齐，防止误切换）

| Mac 分类 (`SSHFailureClassification`) | Win 映射 (`CoreError` subclass) | 是否允许 Native→Compat 切换 |
|--------------------------------------|----------------------------------|------------------------------|
| `transport` (TCP/DNS/超时) | `CoreError::Io / Ssh("timeout")` | ❌ 直接报错 |
| `protocolCompatibility` (KEX/HostKey/Cipher 不匹配) | `russh::Error::KexInit` 等 | ✅ 唯一允许切换 |
| `backendCapability` (no supported auth / kbd-interactive 缺) | `CoreError::Ssh("no auth methods")` | ✅ 允许切换 |
| `authentication` (Permission denied) | `CoreError::Ssh("auth failed")` | ❌ 禁止切换（防暴力重试） |
| `configuration` (本地参数错) | `CoreError::InvalidArgument` | ❌ |
| `unknown` | `CoreError::Other` | ❌ |

---

## 4. 全量功能复用总表（保证“所有功能都有”）

> 按 `FEATURE_ROADMAP.md` + `Bonk/Services/*` 实盘清点。`复用度` 定义：**直接复用**= Rust 已有 Trait 搬运；**适配复用**= Trait 不变、OS 层重写；**平台替换**= 用 Win 原生能力等价实现；**UI 后补**= 功能先通，UI 后期再 1:1。

| # | 功能模块 | Mac 路径 | Win 目标 | 复用度 | 转变方案简述 | 优先级 | UI 后补? |
|---|----------|----------|----------|--------|--------------|--------|-----------|
| 1 | **SSH 连接/重连/KeepAlive** | `SSH/*` 22 文件 | `bonk-core/ssh` | 适配复用 | russh 单引擎先行，ReconnectPolicy 原样移植 | P0 | — |
| 2 | **终端 PTY + 分屏 Tab** | `PTTYSession` + `SessionManager` + `TerminalEngine` | `RusshPtyChannel` + Zustand tabs + xterm.js | 适配复用 | PTY 用 russh channel，布局用 Rust `LayoutStore` DTO | P0 | — |
| 3 | **SFTP 浏览器** | `SFTP/*` 7 文件 + `SFTPMultiTCP` | `sftp/mod.rs` + russh-sftp | 直接复用 | `SftpFileEntry/sort/normalize` 已在 Rust；补 `list/upload/download` 真连 | P0 | UI 后补（先表格） |
| 4 | **端口转发** | `PortForwardService` + `NativePortForward` | `ssh/forward.rs` | 直接复用 | `PortForward` DTO 复用，P1 再通 | P1 | UI 后补 |
| 5 | **JumpHost 跳板** | `JumpHostService` | `SshConnector` hops | 直接复用 | 见 3.3 | P0-1跳 | — |
| 6 | **串口** | `SerialPortService` (IOKit) | `serialport` crate | 平台替换 | `SerialPort` DTO 复用，Win 用 `COMx` + `serialport::SerialPort` | P1 | — |
| 7 | **日志着色** | `LogColorizer/*` 10 文件 + ZeroCopy | `bonk-core/log` (新建) | 直接复用 | 把 `LogClassifier/ZeroCopyScanner/PTYEchoTracker` 原样译为 Rust，xterm.js 只渲染 ANSI | P1 | — |
| 8 | **Shell 集成 / 命令块 / Triggers** | `Shell/*` + `Triggers` | `bonk-core/shell` + `triggers` | 直接复用 | `CommandBlock` + OSC 7 嗅探 + 正则触发，xterm.js marker | P1 | UI 后补 |
| 9 | **会话录制回放** | `Recording/SessionRecordingService` | `bonk-core/recording` | 直接复用 | asciicast v2 (JSON lines) Rust 实现，前端用 `xterm-addon-serialize` 回放 | P1 | — |
| 10 | **AI 助手 (4 供应商)** | `AI/*` 10 文件 + `Providers/*` 5 | `bonk-core/ai` | 适配复用 | `reqwest` + 流式 SSE，`AiProvider` trait 已定，补 OpenAI/Claude/Gemini/Ollama 4 家 | P0-mock → P1真连 | UI 后补 |
| 11 | **Agent 工具循环** | `Agent/*` 13 文件 | `bonk-core/agent` | 直接复用 | `AgentEngine/ToolExecutor/CommandSafety/OperationLog` 全量移植，`execute` 走 `SshSession::execute` | P1 | — |
| 12 | **Quake 下拉终端** | `Quake/*` 10 文件 (Carbon/NSPanel/Animator) | Tauri `globalShortcut` + `window.setAlwaysOnTop` + `window.hide/show` | 平台替换 | Win `RegisterHotKey(Ctrl+`~`)` + 顶部滑入动画(tauri `window` + framer-motion) | P1 | — |
| 13 | **主题 / 外观** | `Themes/*` + `AppStyle` | `src/index.css` tailwind + `ThemeManager` DTO | 适配复用 | Mac `ThemeManager` 的 token (color/font/spacing) 抽为 JSON，Tailwind `oklch` 消费 | P2 | UI 时一起 |
| 14 | **Workspace/布局** | `Models/Layout/*` + `Workspace*` | `bonk-core/models/layout.rs` + Zustand | 直接复用 | `LayoutNode/WindowLayout/LayoutStore` DTO 已有思路，SQLite 持久化 | P1 | UI 后补 |
| 15 | **主机/分组/凭证** | `Models/SSH/*` + `Keychain/*` | `storage` + `keychain` | 适配复用 | `HostItemDto/HostGroupDto/CredentialDto` + `HostStore`+`CredentialStore` 双 Trait | P0 | — |
| 16 | **iCloud 同步偏好** | `UserPreferences` SwiftData singleton | `bonk-core/models/preferences.rs` + SQLite | 平台替换 | Win 用 SQLite `preferences` 表单例行 (`ensurePreferences`)，未来可接 `tauri-plugin-store` | P1 | — |
| 17 | **导入器** | `Import/*` `SessionImporter/TabbyImporter` | `bonk-core/import` | 直接复用 | `SessionImporter` trait 已定，Rust 侧补 ssh_config/Tabby/SecureCRT/Xshell | P1 | — |
| 18 | **团队协作** | `Team/*` 8 文件 | `bonk-core/team` (P2) | 直接复用 | `TeamRelay/Discovery/Host/Guest` 原样移植，Win 先 P2 | P2 | — |
| 19 | **资源监控** | `ServerInfo/ServerResourceMonitor` | `bonk-core/monitor` | 直接复用 | `execute("cat /proc/*")` 解析，复用 `ServerInfo` DTO | P1 | — |
| 20 | **全局热键/广播/效率** | `Focus/*` `Upload/*` `ShellIntegration` | `bonk-core/focus` + Tauri `globalShortcut` | 平台替换 | `FocusManager` 逻辑复用，热键走 `tauri-plugin-global-shortcut` | P1 | UI 后补 |
| 21 | **更新** | `UpdaterManager` (Sparkle) | `tauri-plugin-updater` | 平台替换 | Win 用 Tauri updater + GitHub Release，与 Mac Sparkle 同源 | P1 | — |
| 22 | **崩溃上报** | `CrashReporter` | `tracing` + `tauri-plugin-log` | 平台替换 | 前端 `window.onerror` + Rust `panic hook` | P2 | — |

> **检验标准**：上线前对照本表逐行打 `cargo test` + `tauri dev` 真连演示，缺一行不准发布。

---

## 5. 标准化详细解决方案（按模块）

### 5.1 SSH（最重，单列）

**目录标准**

```
bonk-core/src/ssh/
  mod.rs        → SshSession/PtyChannel/SftpChannel/ForwardChannel trait + SshConnector
  session.rs    → RusshSession (真连) + MockPtyChannel/SftpChannel (回落)
  config.rs     → SshClientConfig (timeout/keepalive/kex 覆盖)
  jump.rs       → JumpChain (hops 递归建链)
  keepalive.rs  → KeepAlivePolicy
  reconnect.rs  → ReconnectPolicy (backoff)
  error.rs      → SshFailureClassification + classifier
  host_key.rs   → HostKeyValidator + PersistentHostKeyStore (SQLite)
```

**状态机（与 Mac `SSHSessionState` 对齐）**

```
Idle → Connecting → Connected → Disconnected
                      ↑           |
                      └─ ReconnectPolicy 判定是否重进 Connecting
```

**配置构建（与 `SSHConnectionConfigBuilder` 对齐）**

```rust
HostItemDto + CredentialStore -> SshConnectionConfig {
  host, port, username, auth_type, secret: Option<String> #[serde(skip)],
  jump_hosts: Vec<JumpHostDto>, timeout_secs=15, keepalive_secs=30,
  kex_algorithms/host_key_algorithms: Option<Vec<String>> // 仅 legacy 填
}
```

**Tauri 侧持有（解决当前 TODO）**

```rust
// src-tauri/src/main.rs 标准写法
struct PtyHandle { channel: Box<dyn PtyChannel> } // 需 Arc<Mutex<...>>
type SessionMap = Arc<Mutex<HashMap<String, (Arc<dyn SshSession>, PtyHandle)>>>;
#[tauri::command] async fn ssh_write(id, data) { map[id].1.channel.write(data).await }
#[tauri::command] async fn ssh_resize(id, cols, rows) { map[id].1.channel.resize(size).await }
```

### 5.2 存储（SwiftData → SQLite 标准化）

**铁律（来自 AGENTS.md）**

- 不改 `storeName`（Win 本就无 SwiftData，用 SQLite 文件 `bonk.db` 在 `app_data_dir`）
- 不改已有字段，只增 `Option` 字段 / 新增表
- 不使用 `String?` 存外键，用关系表

**表设计（JSON blob 最简，后续可拆列）**

```sql
CREATE TABLE IF NOT EXISTS hosts (id TEXT PRIMARY KEY, json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS groups (id TEXT PRIMARY KEY, json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS credentials (id TEXT PRIMARY KEY, json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS backend_profiles (host TEXT, port INT, auth TEXT, json TEXT, PRIMARY KEY(host,port,auth));
CREATE TABLE IF NOT EXISTS preferences (id INT PRIMARY KEY CHECK(id=1), json TEXT);
CREATE TABLE IF NOT EXISTS ai_conversations (id TEXT PRIMARY KEY, json TEXT);
```

**Trait 标准（已在 `storage/mod.rs` 定好，扩展它）**

```rust
#[async_trait] trait HostStore { list/get/upsert/delete }
#[async_trait] trait GroupStore { … }
#[async_trait] trait CredentialStoreMeta { … } // 存 metadata，secret 仍走 keyring
```

### 5.3 钥匙串（Security.framework → Credential Manager）

```rust
trait CredentialStore { get/set/delete }
// Mac: Security.framework (keychain)
// Win: keyring (Credential Manager) + feature `keychain-os`
// 命名：password_key(host_id) = "bonk.host.{uuid}.password" 与 Mac KeychainHelper 完全对齐
```

### 5.4 PTY / Terminal

- **后端**：`RusshPtyChannel` (russh `Channel<Msg>` + `request_pty("xterm-256color")` + `request_shell`)，输出用 `mpsc::channel(512)` 聚合 → `emit`.
- **前端**：`xterm.js 5.3 + @xterm/addon-fit + @xterm/addon-web-links`，`TerminalView.tsx` 已双路径（mock / Tauri），补齐 `onData/onResize` 闭环即可。
- **性能**：复用 Mac `TerminalEngine` 的 watermark 256K + coalescer + display tick（前端用 `requestAnimationFrame` 聚合 `term.write`）。

### 5.5 SFTP

```rust
trait SftpChannel { real_path/list_dir/create_dir/remove/upload/download/exists/close }
```

- P0：`open_sftp` 后 `list_dir("/home")` 通。
- 传输：`tokio::fs` + `futures::stream` 并发分片，进度 `onProgress: Fn(f32)` 通过 Tauri `emit("sftp-progress://id")` 到前端。
- 复用 `sftp/mod.rs` 的 `normalize_remote_path` + `sort_entries`。

### 5.6 AI / Agent

- `bonk-core/ai/mod.rs` 已定 `AiProvider::complete`，补 `reqwest` + `eventsource` 流式。
- 4 家 Provider：`OpenAiCompatProvider` (含 DeepSeek/Groq) / `ClaudeLLMProvider` / `GeminiLLMProvider` / `OllamaLLMProvider`，与 Mac `LLMProviderFactory` 1:1。
- Tool-loop：`AgentEngine` 在 Rust 侧跑 `LLMToolCall(run_command) → SshSession::execute → 回填 tool_result → 再 complete` 循环，≤8 轮、30s 超时、4000 字符截断，与 Mac `AgentToolExecutor` 对齐。
- 终端镜像：`AITerminalMirror` → Tauri `emit("ai-mirror://tabId", ansiLine)`.

### 5.7 串口（平台替换，接口统一）

```rust
trait SerialPort { open(path, baud)/read/write/close }
// Mac: IOKit  → Win: serialport crate (COMx)
```

### 5.8 Quake 终端（平台替换，行为对齐）

| 能力 | Mac | Win |
|------|-----|-----|
| 热键 | Carbon `RegisterEventHotKey(Cmd+`) | `tauri-plugin-global-shortcut` `Ctrl+`` |
| 窗口 | `NSPanel` floating + `WindowAnimator` 滑入 | `WebviewWindow` `alwaysOnTop/decora­tions:false/transparent:true` + framer-motion 滑入 |
| 失焦隐藏 | `QuakeFocusManager` | `window.onFocusChanged` |
| 多显示器 | `ScreenManager` | `tauri::Manager::getWindow("main").currentMonitor()` |

### 5.9 导入/导出

`SessionImporter` trait 保持不变：

```rust
trait SessionImporter { fn name(&self)->&str; fn discover(&self)->Result<Vec<HostItemDto>> }
```

实现：`SshConfigImporter` / `TabbyImporter` / `SecureCrtImporter` / `XshellImporter`，复用 Mac 的解析逻辑。

---

## 6. 目录/命名/DTO 标准化

### 6.1 DTO 命名（前后端同构）

```ts
// bonk-win/src/lib/types.ts 必须与 bonk-core/src/models/host.rs 的 serde(rename_all="camelCase") 对齐
type AuthType = "password" | "privateKey" | "certificate" | "secureEnclave"
interface HostItem { id:string; name:string; host:string; port:number; username:string; authType:AuthType; groupId?:string }
```

### 6.2 错误码（C ABI + Tauri 共用）

```rust
enum CoreErrorCode { Ok=0, Ssh=1, Sftp=2, Pty=3, Storage=4, Keychain=5, Ai=6, NotConnected=7, Cancelled=8, InvalidArgument=9, Io=10, Unknown=99 }
```

### 6.3 Tauri Invoke 命名

```
core_version / core_validate_host
ssh_connect / ssh_disconnect / ssh_write / ssh_resize
sftp_list / sftp_upload / sftp_download / sftp_mkdir / sftp_remove
host_list / host_upsert / host_delete / group_list / group_upsert
ai_complete / ai_complete_stream / agent_run
serial_list / serial_open / serial_close
```

### 6.4 前端 Store 标准化

```
src/lib/store.ts (Zustand) → 后续拆
  hostsSlice / tabsSlice / layoutSlice / sftpSlice / aiSlice
  每个 slice 只存 DTO，不存业务逻辑；业务走 invoke → bonk-core
```

---

## 7. 实施路线图（保功能，不追 UI）

### P0 — 打通最小可发布闭环（1-2 周）

- [ ] `bonk-core/ssh` 私钥 auth + `ssh_write/resize` 句柄持有（`SessionMap` 改存 `PtyChannel`）
- [ ] `bonk-win` `TerminalView` 真连闭环（打字→ssh_write→回显，resize 联动）
- [ ] `HostStore` SQLite 真表 + `invoke host_*` 接通 Sidebar 真数据（替换 MOCK_HOSTS）
- [ ] SSH Config 导入最小可用 + 密钥生成（ed25519）最小可用
- [ ] 打包 `tauri build` 出 `.msi/.exe` 能装能连

**验收**：Win 10/11 双机，密码+私钥各连 3 台现代主机，SFTP `ls` 通。

### P1 — 补齐 Mac 功能平移（2-3 周）

- [ ] JumpHost 1跳 → N跳
- [ ] KeepAlive + ReconnectPolicy + HostKey 持久化 + 算法定向注入
- [ ] SFTP 真连（单连接多路复用）+ 上传/下载 + 进度
- [ ] AI 4 供应商真连（reqwest 流式）+ Agent `run_command` 工具循环 + 安全确认
- [ ] SerialPort + PortForward(L/R) + 录制(asciicast) + Shell集成/命令块/Triggers
- [ ] LogColorizer Rust 移植 + Quake 热键 + Workspace 布局持久化

**验收**：对照 §4 全表 P1 项，逐项 `cargo test` + 真机演示，Mac 有的 Win 都有。

### P2 — 补齐护城河与企业能力（按需）

- 团队协作、SFTP 并行/压缩、多路复用、主题系统、审查日志、SSO、Updater

### P3 — UI 精修（功能 100% 后再启动）

- 像素级复刻 Mac：标题栏/侧栏/工具栏/Inspector/文件树/图标，不在此阶段考核

---

## 8. 风险与对策

| 风险 | 对策 |
|------|------|
| russh 在 Win 上行为与 Citadel 不一致 | 以 `SshSession` trait 为界，新增 `SshFailureClassification` 单测矩阵，legacy 自动切兼容子进程 |
| ConPTY 与 russh PTY 的信号/编码差异 | `TerminalEngine` 的 watermark/coalescer 在 Rust 前端统一收口，前端只 `term.write`，不二次解码 |
| keyring 在 Win 受限/企业策略 | 回落 `InMemoryCredentialStore` + 明文提示，接口不变 |
| SQLite 迁移与 Mac SwiftData 不兼容 | Win 独立 `bonk.db`，不共用 Mac 库；DTO JSON blob 保证向前兼容 |
| AI 流式与 tool-call 各家差异 | 与 Mac `AIProviderNetworking+Agent/Routing/CapabilityProbe` 对齐，Rust 侧一处适配四家 |
| Tauri 窗口/热键与 Win 版本差异 | `globalShortcut` 失败回落菜单触发，Quake 非阻塞 |

---

## 9. 校验清单（发版前逐项勾）

- [ ] `bonk-core: cargo check --all-features && cargo test` 绿
- [ ] `bonk-win: npm run build && cargo check -p bonk-win` 绿
- [ ] 真机：密码/私钥/跳板 各 2 台，SFTP 上传/下载 100MB，AI 问答+Agent `df -h` 工具调用通
- [ ] §4 全表 P0/P1 无 `缺`，`core_version` 与 Mac `MARKETING_VERSION` 对齐
- [ ] 安装包 `.msi` 在干净 Win10/11 虚拟机可装可卸可升级（Tauri updater）

---

## 10. 附：当前已定 Trait 速查（禁止重复定义）

```rust
// ssh/mod.rs
trait SshSession { open_pty(size)->PtyChannel; execute(cmd)->CommandResult; open_sftp()->SftpChannel; close() }
trait PtyChannel { write(data); resize(size); next_output()->Option<Bytes>; close() }
trait SftpChannel { real_path; list_dir; create_dir; remove; upload; download; exists; close() }
// storage/mod.rs
trait HostStore { list/get/upsert/delete }
// keychain/mod.rs
trait CredentialStore { get/set/delete }
// ai/mod.rs
trait AiProvider { complete(req)->AiCompletionResponse; name()->&str }
```

> 后续新增能力，**只在 `bonk-core` 加 trait 扩展 + 新文件**，禁止在 `bonk-win` 写独立 SSH/SFTP/AI 实现。

---

*本方案是唯一执行标准，后续变更以 PR 修改本文件为准。*
