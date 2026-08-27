# 日志着色 S 级路线图 — 从 A- 到 S 的半步

> 状态：2026-08-27 功能 PASS，架构 A，梯队 A-。剩余扣分全在“硬编码开放性”，非正确性。
> 对标：SSH 终端赛道已第一梯队（> Termius/Tabby/iTerm2 Trigger/Warp）；专用日志查看器（lnav/Datadog/Papertrail）为 S，需补开放性。

## 已封顶（不再动）

- Token != Log Line、my-alert-service、docker ps 孤立 alert、Shell prompt/echo 优先
- Terminal Grid → Incremental → Classifier → Zero-Copy Scanner → Lazy Cache → Highlight Overlay → Renderer
- 精准 > 召回、multiline continuation、syslog PRI / nginx / Java / BSD / logfmt level=
- 三档位隔离：Terminal 60/120 FPS / Progress 10~20 FPS / Worker 后台 0-delay utility
- DegradedMode 5k/50k + watermark 256K 保渲染
- PTY 真回显 correlation（PTYEchoTracker 64 条环形，ShellIntegration OSC133 C + PTYSession sendInput 双喂）+ heuristic fallback 永不扩张
- SFTP unknown indeterminate + 真 MB、50ms 聚合前置（ProgressMerger + SFTPProgressThrottler + singleStream 双闸）

## 到 S 的半步 — 缺口清单

### P0 本周可合（~2h，直接 A- → A）

| 缺口 | 现状 | S 要求 | 落点 |
|------|------|--------|------|
| 格式覆盖 | `timestamp+level / PRI / nginx / Java / BSD / bracket / dockerKV` | 补 `JSON {"level":"error"}` / `{"severity":"ERR"}` / `level:error` / `k8s zap/zerolog` / `Python traceback` | `LogPatterns.swift` 新增 `jsonLevel` / `logfmtLevel` 两段正则，复用同一 `priority` |
| 可配置 | `LogColorizerConfig.isEnabled` 全局；`HostItem` 无 `logProfileID`；改正则需发版 | `HostItem.logProfileID → LogProfileStore (SwiftData, additive, optional) → Settings/LogPatternsView` | `Models/SSH/HostItem.swift` 加 `logProfile: LogProfile? @Relationship optional`；新增 `LogProfile`/`LogPatternRow` 模型；`LogPatterns.allPatterns` 改为 `store.activePatterns ?? defaultPatterns` |
| 预览 | 无 | Settings 内实时预览 10 行样例 + 颜色拾取 | `Views/Settings/LogPatternSettingsView.swift` |

> P0 合后即 `A`，用户无需发版即可认他的日志。

### P1 下周（~1d，A → S-）

| 缺口 | 现状 | S 要求 |
|------|------|--------|
| 状态隔离 | `LogClassifier static shared + NSLock previousWasLog` 单例跨 tab 串扰 | `per TerminalEngine` 实例化 `LogClassifier()`；`IncrementalLogDetector` 按 `tabID` 持有 |
| 真 Overlay | `NSMutableString + "\u{1B}[31m"` 喂 `SwiftTerm.feed`（ pragmatically correct，对 `hasANSI` 行需跳过） | `fork SwiftTerm DecorationProvider`（VS Code 做法），`HighlightOverlay` 直合成 `CellAttributes`，不注 ANSI |
| 零分配极限 | `scan` 每 log 行 23 次 `regex.matches`（10+13 level） | `Combined level regex (EMERG\|ALERT\|...) 单次` + `hyperscan/re2 prefilter` 压至 `30ms/10k` |

### P2 有空（~0.5d，S- → S）

- `UserDefaults 导入 lens`（`lnav` 格式复用）
- `SFTPProgressThrottler` 已 50ms，`LogMerger` 同 50ms，已封顶；不再动

## 不做清单（已刻意保留）

- 不为 `ShellIntegration` 加更多 `shellVerbs` 黑名单 — 已注 `Never expand`，真解靠 `PTYEchoTracker`
- 不把 `IncrementalLogDetector.viewportChanged` 强行接入 `SwiftTerm visibleRows`（当前 ANSI 注入已满足 60 FPS，真 Overlay 再接）

## 验收标准

- `xcodebuild test` 全绿，`LogColorizerReproTests 120ms/10k < 300ms`，`SFTPProgressReproTests unknown progress==nil` 保持
- 新增 `LogProfile` 仅 `optional` 属性，`storeName` 不变，`additive migration` 验证：旧版建数据 → 新版装 → 数据完整

## 当前决策

- 功能无问题，A- 可 Release；P0 半天即可封 A，P1 一天封 S-。本档先落地，P0 另起分支。
