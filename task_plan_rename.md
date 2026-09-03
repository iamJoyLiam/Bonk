# Plan: 变量名合规化重命名 (identifier_name 3-40)

## Goal
消除 `swiftlint` 的 `identifier_name` 违规（短于 3 字符），使全仓 `Bonk/` 通过 `swiftlint lint Bonk` 无 `identifier_name` 警告，符合 Swift API Design Guidelines。

## Scope
- 仅改变量/参数/枚举成员命名，不改行为与 schema
- 涉及 `Bonk/` 下约 110 处 `identifier_name` 违规，分布：
  - 高频短名：`m`(35), `p`(30), `r`(17), `s`(14), `t`(12), `ch`(12), `c`(10), `v/h` 等
  - 近期引入：`AddHostSheet.vm/t/p`, `HostListView.p`, `AuthRetrySheet.nv/r/fp`, `SessionManager.er/fp/af/tf`, `LayoutStore.h/v/c/t/ch/w` 等
  - 新导入器：`GenericCSVImporter` 的 `k`, `ns`, `n` 等

## Strategy
分 3 批小步提交，降低风险，每批 `BUILD SUCCEEDED` 后再下一批：

### Phase 1 - 近期功能文件（本次 PR 已改的）
- `AddHostSheet.swift`: `vm → formViewModel`, `t → detectedType`, `p → logProfile`
- `HostListView.swift`: `p → backendProfile`
- `AuthRetrySheet.swift`: `nv → newValue`, `r → retryResult`, `fp → fingerprint`
- `UnifiedImportView.swift`: 已合规，检查 `p` 等
- 新导入器：`Electerm/WindTerm/GenericCSV/ITerm2` 内的 `k/pk/p` 等 → `privateKey/privateKeyValue`, `ns → namespace` 等
- `ExportHostsView.swift`, `HostItem.swift` 已合规复查

### Phase 2 - 核心高频文件
- `LayoutStore.swift`: `h/v → horizontal/vertical`, `c → child`, `t → tab`, `ch → childNode`, `w → weight`, `a/b → first/second`, `s → string`
- `SessionManager.swift` / `SessionManager+VNext.swift` / `SessionManager+SplitPane.swift`: `er → errorResult`, `fp → fingerprint`, `r → retryResult/tab`, `s → session`, `af → authFailure`, `tf → transportFailure`, `m → message`
- `BonkAppDelegate.swift`: `h → hostItem`, `vm → viewModel`, `p → profile`
- `TriggerEngine.swift`, `DisplaySource.swift`, `Team*` 等

### Phase 3 - 剩余长尾
- `LogProfile`, `HighlightFields`, `PatternEditSheet`, `SSHNetworkService`, `OpenSSHBackend`, `SSHFailure`, `SSHProcessFailure`, `SystemWakeMonitor`, `SFTP*` 等剩余 `m/p/s/t` 等
- 枚举成员 `h/v` → `horizontal/vertical`

## Lint 配置微调（可选，待定）
- 若 `id/ip/url` 等行业通用 2 字符被误伤，考虑在 `.swiftlint.yml` 加 `allowed_symbols: [id, ip, url, db]`，但本次先以重命名为主，不改配置，除非用户同意

## Acceptance
- [ ] `swiftlint lint Bonk 2>&1 | grep identifier_name` 为 0
- [ ] `xcodebuild -project Bonk.xcodeproj -scheme Bonk -destination 'platform=macOS' build` 成功
- [ ] 功能回归：侧边栏标签、导入、终端分屏、认证重试无回归

## Execution
- 每文件 `Read → Edit → Build → Lint` 循环
- 保持 `git diff` 最小，仅改名不改逻辑
- 每 Phase 一 commit，英文 message
