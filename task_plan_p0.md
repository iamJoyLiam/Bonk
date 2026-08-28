# P0 三件套 — 冲 S 梯队

> 接 `docs/log-colorizer-s-tier-roadmap.md`，`Strong 已闭环`，差 `P0` 三件封 `S`

## 阶段 1 — 日志可配 (0.5d) `P0-1`
- [ ] 1.1 模型: `LogProfile` + `LogPatternRow` SwiftData (additive, optional)
  - `LogProfile: id, name, isDefault, createdAt, patterns: [LogPatternRow] @Relationship(cascade)`
  - `LogPatternRow: id, name, pattern, ansiCode, priority, enabled`
  - `HostItem.logProfile: LogProfile? @Relationship(optional)` — additive, 不改 storeName
- [ ] 1.2 Store: `LogProfileStore` (@Observable, @MainActor) — CRUD + 默认 3 套 (Default/Nginx/JSON) + 导入导出
- [ ] 1.3 Seam: `LogPatterns` 改为 `store.activePatterns ?? defaultPatterns`，`LogClassifier/LogColorizer` 读 Store 单例
- [ ] 1.4 UI: `Settings/LogPatternSettingsView` — List + 颜色拾取 + 正则校验 + 实时预览 10 行样例 + per-host 选择器
- [ ] 1.5 迁移验证: 旧版建数据 → 新版装 → 数据完整 (additive)

## 阶段 2 — Zmodem (0.5d) `P0-2`
- [ ] 2.1 现状: `ZmodemHandler` 有壳，`PTYSession` 已接 `** + ZDLE` 检测，但 `SFTPWindow` 未暴露
- [ ] 2.2 接线: `TerminalTabView` 收到 `ZmodemHandler.onReceiveFileRequest` → 弹 `NSSavePanel` (下载) / `NSOpenPanel` (上传 `rz`)
- [ ] 2.3 指令: `sz file` 自动 `ZmodemHandler.startSend`，`rz` 自动 `startReceive`，`SFTPWindow` 复用 `SFTPService` 进度条
- [ ] 2.4 测试: 本地 `sz` 10M 文件，断点续传取消

## 阶段 3 — FIDO2/YubiKey (1d) `P0-3`
- [ ] 3.1 调研: `OpenSSHBackend` 已透传 `IdentityFile`，需加 `SecurityKey` 分支 (`-O` / `sk-` 类型)
- [ ] 3.2 模型: `Credential` 加 `isSecurityKey: Bool` (optional) + `CredentialStore` 标记
- [ ] 3.3 接线: `SSHConnectionConfigBuilder` 识别 `sk-ecdsa-sha2-nistp256@openssh.com` / `sk-ssh-ed25519@openssh.com`，`OpenSSHBackend.sshArguments` 加 `-o SecurityKeyProvider=internal`
- [ ] 3.4 UI: `KeychainManagerView` + `HostForm` 加 `Security Key` 开关 + `Touch ID` 提示
- [ ] 3.5 验证: YubiKey 5 实机 `ssh -o IdentitiesOnly=yes` 直连

## 决策
- D1: 三件均 additive，不改 storeName，不动现有正则
- D2: 日志可配优先，因已 `A-` 且改动最小，收益最大
- D3: Zmodem 复用现有 `ZmodemHandler`，不另起新传输
- D4: FIDO2 仅 OpenSSH 路径，Citadel 路径待上游支持

## 进度
- 2026-08-28: 规划完成，开工 P0-1
