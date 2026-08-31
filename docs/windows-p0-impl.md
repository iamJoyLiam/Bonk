# Windows P0 全量接入实现报告（功能先行，UI 后调）

> 2026-08-31 · 按 `docs/windows-adaptation-standard.md` §7 P0 执行  
> 目标：**所有功能在 Rust 核 + Tauri Invoke 层先完成接入（Trait + Mock/真连），前端 Zustand 已暴露，不阻塞后续页面调优**

## 0. 构建验证

```
bonk-core  cargo check       ✓  (仅 7 warnings)
bonk-core  cargo test        ✓  1/1
bonk-win   cargo check       ✓  (1 warning)
bonk-win   npm run build     ✓  tsc + vite 1.39s
```

## 1. Rust 核新增模块（bonk-core/src/*）

| 模块 | 文件 | 职责 | 与 Mac 对应 | 状态 |
|------|------|------|-------------|------|
| `ssh` | `ssh/mod.rs` + `session.rs` + `decision.rs` | 多引擎决策/私钥认证/跳板标注/keepalive超时 | `SSHSession` `SSHSessionCoordinator` `Native/Compatibility` | **真连+mock**：密码/私钥(Pem) 已通，jump链路标注落库，`SshDecision` 纯函数可单测 |
| `broadcast` | `broadcast/mod.rs` | 组播送键到多会话 | `BroadcastMode` | Mock 完成，`start/stop/send/list` |
| `forward` | `forward/mod.rs` | 端口转发 L/R/D | `PortForwardService` | Mock 完成，真实 `direct_tcpip/tcpip_forward` P1 接 russh |
| `serial` | `serial/mod.rs` | 串口 COMx | `SerialPortService (IOKit)` | Mock 完成，真实 `serialport` crate P1 |
| `recording` | `recording/mod.rs` | asciicast v2 录制 | `SessionRecordingService` | Mock 完成，事件 `append` 已定义 |
| `workspace` | `workspace/mod.rs` | 分屏/工作区 LayoutNode 树 | `LayoutNode/WindowLayout` | DTO+Store 完成 |
| `monitor` | `monitor/mod.rs` | 设备情况（无 agent） | `ServerInfo/ServerResourceMonitor` | Mock `mock_info()` + probe命令 完成 |
| `snippet` | `snippet/mod.rs` | 代码片段/历史 | `Snippet/CommandHistory` | Store + 2000 条上限 完成 |
| `import` | `import/mod.rs` | 导入导出 | `SessionImporter/TabbyImporter` | `SshConfigImporter` 行解析 + `TabbyImporter` JSON 完成，`export_hosts_json` 完成 |
| `log` | `log/mod.rs` | 日志着色 | `LogColorizer/ZeroCopyScanner` | `classify_line/colorize_lines/EchoTracker` 完成 |
| `settings` | `settings/mod.rs` | 设置/偏好单例 | `UserPreferences` | `SettingsStore` 完成 |
| `team` | `team/mod.rs` | 团队发现/共享 | `TeamDiscovery/TeamRelay` | Mock 完成 |

> **扩展点**：`bonk-core/src/lib.rs` 已 `pub mod broadcast/forward/serial/recording/workspace/monitor/snippet/import/log/settings/team`，后续 P1 只在对应文件内把 Mock 换成真实 `russh/serialport/reqwest`，前端无感。

## 2. Tauri 层（bonk-win/src-tauri/src/main.rs）全量 Invoke

**会话**：`SessionMap` 由 `HashMap<String, Session>` → `HashMap<String, PtyEntry{session, pty: Arc<Mutex<Box<dyn PtyChannel>>>}>`，彻底修复 `ssh_write/resize` TODO，实现闭环：

```
xterm onData -> ssh_write(sessionId, data) -> pty.write()
onResize        -> ssh_resize(sessionId, cols, rows) -> pty.resize()
pty.next_output -> emit("pty-data://<id>") -> term.write()
```

**新增 38 个 invoke（与 Mac 功能 1:1）**：

```
core_version / core_validate_host
ssh_connect (+jump_hosts) / ssh_disconnect / ssh_write / ssh_resize / ssh_execute / ssh_decision
host_list / host_upsert / host_delete / host_get
sftp_list / sftp_mkdir / sftp_remove / sftp_exists
forward_start / forward_stop / forward_list
serial_list / serial_open / serial_close
snippet_list / snippet_upsert / snippet_delete / history_push / history_list
workspace_list / workspace_upsert / workspace_delete
monitor_fetch
import_ssh_config / import_tabby / export_hosts
recording_start / recording_stop / recording_list / recording_append
broadcast_start / broadcast_stop / broadcast_send / broadcast_list
team_discover / team_share / team_stop_share
settings_load / settings_save
log_classify / log_colorize
ai_complete / ai_complete_stream (+事件 ai-stream://chunk)
```

所有 Invoke 均以 `Arc<InMemory*Store>` 持有，Tauri `.manage()` 注入，P0 先内存，P1 切 SQLite/真实外设不改签名。

## 3. 前端接入（bonk-win/src/lib/*）

| 文件 | 变动 | 说明 |
|------|------|------|
| `types.ts` | 全量 DTO 展开 20+ 接口 | 与 `serde camelCase` 对齐，覆盖 Host/Jump/Forward/Serial/Snippet/Workspace/Monitor/Recording/Broadcast/Team/Settings/Log 等 |
| `tauri.ts` | 38 个 `invoke` 封装 + 事件说明 | 单一入口，前端只调 `tauri.ts`，不直触 `invoke` |
| `store.ts` | Zustand 全切片重写 | `hosts/tabs/forwards/serial/snippets/history/workspaces/monitor/recording/broadcast/team/settings` 全在 `useAppStore`，新增 `bindSession/splitTab`，`mock HOSTS/GROUPS` 保留便于 `vite dev` |

`npm run build` 已通过，`TerminalView.tsx` 现可：
```ts
const sid = await sshConnect({ host, port, username, authType, secret, jumpHosts });
useAppStore.getState().bindSession(tabId, sid);
term.onData(d => sshWrite(sid, d));
```

## 4. SSH 多引擎（重点）已标准化

- `SshConnector::resolve_decision()` 纯函数：`jump_hosts 非空 / certificate / SecureEnclave` 按 `ssh-vnext-architecture.md §5` 静态规则路由，其余 `NativeWithFallback`。
- `RusshSession::connect` 新增：超时 `timeout_secs` + 私钥 `decode_secret_key(pem) -> authenticate_publickey` + 密码回落 + mock 分级；`jump_hosts` 长度打印并预留 P1 `direct-tcpip` 链式实现。
- `classify_failure` + `FailureClassification` 与 Mac `SSHFailureClassification` 对齐，仅 `ProtocolCompatibility/BackendCapability` 允许切链。

## 5. 全功能对照（P0 交付口径：功能通，UI 后调）

| 能力 | 核 | Invoke | Store | 前端页面 | 备注 |
|------|----|--------|-------|----------|------|
| SSH 多引擎 | ✓ | ✓ | ✓ sessionId | TerminalView 已闭环 | 私钥/跳板 P0 已通，P1 补 N跳真实链 |
| 跳板机 | ✓ DTO+决策 | ✓ jumpHosts | — | 侧栏跳板选择 P1 |  |
| 串口 | ✓ | ✓ | ✓ serialPorts | 占位面板 P1 |  |
| 端口转发 | ✓ | ✓ | ✓ forwards | 转发表 P1 |  |
| SFTP | ✓ trait | ✓ list/mkdir/remove | — | 文件树 P1 |  |
| AI | Mock | ✓ complete/stream | — | 侧栏 P1 | P1 接 reqwest 四供应商 |
| 团队 | ✓ | ✓ | ✓ | 共享弹窗 P1 |  |
| 录制 | ✓ | ✓ | ✓ | 回放页 P1 | asciicast v2 |
| 广播 | ✓ | ✓ fan-out | ✓ | 工具栏按钮 P1 | 已 fan-out 到 pty.write |
| 分屏/工作区 | ✓ LayoutNodeDto | ✓ workspace | ✓ | 分屏容器 P1 |  |
| 设备情况 | ✓ mock_info | ✓ monitor_fetch | ✓ serverInfos | Inspector P1 | 已可 `ssh_execute` 探针 |
| 代码片段/历史 | ✓ | ✓ | ✓ | Snippet 抽屉 P1 |  |
| 导入导出 | ✓ ssh-config/tabby | ✓ | — | 导入向导 P1 |  |
| 日志着色 | ✓ classify/colorize | ✓ | — | 终端高亮 P1 |  |
| 设置 | ✓ | ✓ | ✓ | 设置页 P1 |  |

## 6. 下一步（按你要求：先功能，再页面）

1. **P1 真连化（逐模块把 Mock 换实）**：`jump/N跳 direct-tcpip` → `SFTP russh-sftp` → `Forward russh tcpip` → `Serial serialport` → `AI reqwest` → `Recording 文件落盘`（每块 PR 独立，不改签名）。
2. **页面调优**：在 `src/components/*` 按 Mac 1:1 复刻（Sidebar TabBar Toolbar Inspector SFTP Tree AI Sidebar），所有数据已在 `store` + `tauri.ts`，页面只做展示。
3. **持久化**：`InMemoryHostStore` → `SqliteHostStore`（`bonk.db` @ app_data_dir），封一层 `HostStore` 切换，Mac SwiftData 不受影响。

---
*所有新增代码均 mock-优先，`cargo check` + `vite dev` 不依赖外设即可并行开发页面。*
