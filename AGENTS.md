# Bonk Project Guidelines

## Database (SwiftData) Rules

### Schema Changes
- **NEVER** change `storeName` — always use default (no explicit name). Changing it creates a new empty database.
- **NEVER** modify existing model properties (rename, change type, delete). Breaks migration.
- **ONLY** add new models or add optional properties to existing models.
- **NEVER** use destructive migration fallback. Fatal error on migration failure.
- **NEVER** use `String?` for entity references. Use `@Relationship`.
- **NEVER** open a second `ModelContainer` against the live store, especially
  with a partial `Schema`. SwiftData migration DROPs every table outside the
  opened model's schema — v2026.4.3 wiped all hosts this way via a 1-entity
  `Schema([UserPreferences.self])` with default (file-backed) config. Always
  read through `BonkApp.sharedModelContainer`; tests use in-memory stores only.

### Current Issues
- ~~`HostItem.group: String?`~~ ✅ Fixed in v2026.0.4 — added `groupRef: HostGroup?` @Relationship
- ~~`HostItem.credentialID: String?`~~ ✅ Fixed in v2026.0.4 — added `credentialRef: Credential?` @Relationship
- ~~`UserPreferences` — no single-instance constraint~~ ✅ Fixed in v2026.0.3 (ensurePreferences + fallback)
- ~~AI conversations stored in UserDefaults~~ ✅ Fixed in v2026.0.3 (migrated to SwiftData)
- ~~AI providers stored in UserDefaults~~ ✅ Fixed in v2026.0.4 (migrated to SwiftData, dependency injection)

### Legacy Properties (kept for migration, do not use)
- `HostItem.group: String?` — deprecated, use `groupRef`
- `HostItem.credentialID: String?` — deprecated, use `credentialRef`

### UserPreferences Singleton Pattern
SwiftData has no built-in singleton mechanism. The correct pattern is:
1. `ensurePreferences()` in `onAppear` — inserts if array is empty
2. `@Query` + `first ?? UserPreferences()` — fallback is transient, never persisted
3. Never use fixed UUID — breaks iCloud sync, not idiomatic SwiftData

### Migration Checklist (before every release)
1. Does any existing model property change? → DO NOT SHIP
2. Is storeName unchanged? → Must be default (no explicit name)
3. Are all new models/properties additive only? → Safe
4. Test: install old version → create data → install new version → data intact

## Release Process
1. All code changes committed locally
2. Version bump in project.pbxproj — **两个字段必须同时更新**:
   - `MARKETING_VERSION` = `X.Y.Z` (用户可见版本号，如 `2026.0.22`)
   - `CURRENT_PROJECT_VERSION` = `XYZ` (内部构建版本号，如 `202622`，Sparkle 用此判断更新)
3. Write English release notes to `/tmp/release_notes_<VERSION去点>.md`
4. Run `./scripts/release.sh <VERSION>` — 编译→DMG→签名→验签→appcast→GitHub Release(`--latest`)→发布后验证，
   一气呵成。**不许手拆步骤；没有 `PASS` 就是没发布完。** DMG 只在 /tmp (NEVER in git)
5. Single commit for release + tag + push

## Code Principles — No Unnecessary Hardcode
- **非必要不硬编码 — 硬编码是害群之马**：定值/尺寸/颜色/文案/路径/魔法数字必须来自设计 token / 系统常量 / 配置 / 本地化，禁止直接写死 `12`/`6`/`20`/`0.3` 等。能自适应就不定宽。
- 布局优先自适应：`GeometryReader` / `ViewThatFits` / `frame(maxWidth:.infinity)` / 自动 `truncation` / `lineLimit`，避免定宽定高。
- 状态切换避免 View 替换导致的 layout recalc：如 SFTP path `Text ↔ TextField` 应为**单一 TextField** `ZStack` `opacity`/`disabled` 切换，保持 `intrinsic size` / `baseline` 不变；不要用 `if` 两个完全不同 View。
- Baseline 对齐显式化：`Text` 与 `TextField` 即使同 `font` / 同 `frame`，`ZStack .leading` 默认 `center` 会导致 `1-2px` 基线抖动，需 `frame(height:28)` + `frame(height:16-18)` + `baselineOffset(-1)` 或单一 `TextField` 方案，达到 Finder 地址栏“光标出现文字不动”。
- `animation(nil)` 只能关动画，不能阻止 `body recompute → layout recalculation → view replacement` 的跳动，根因在 View 身份变化。

## Security Invariants (P0/P1 baseline, 2026-09-29)

Production paths MUST NOT convert real infrastructure failures
into successful mock results.

Authentication may proceed only after the host key has been
accepted by the configured trust policy. TOFU acceptance is a
valid trust-policy decision for first use.

Secrets MUST NEVER be reused across incompatible authentication
semantics (e.g. private-key material as password).

Untrusted remote content MUST NOT cross into privileged local
execution without an explicit trust boundary.

Concretely: real SSH/SFTP failure → `Err` → UI shows failure
(never `Ok(mock)` → "Connected"); host-key TOFU check runs
inside the validator callback *before* auth, not as a post-hoc
compare after connect; fix + regression per batch, never one
giant patch for all findings at once.

## Security Regression Methodology (2026-09-29)

**行为门禁优先于结构存在性。** Security guards MUST be tested for
enforced behavior, not merely for the existence or wiring of guard code.

### Required pattern for every security boundary

1. **Behavioral regression test** — exercise the actual protected
   operation and verify the unsafe behavior is rejected. Do not rely
   only on counting assignments, method invocations, guards, or
   reflection-visible structure.
2. **Pure decision-function test** where practical — extract security
   decisions into deterministic functions with explicit inputs and
   outputs, and test allow and deny paths independently of transport or
   persistence wiring.
3. **Wiring guard** — verify the production path actually invokes the
   decision logic. A pure predicate without production wiring is
   insufficient.
4. **Adversarial mutation** — intentionally weaken, bypass, or remove
   the guard. The regression suite MUST fail. If removing the guard
   leaves the suite green, the security test is insufficient.

### Rationale

A green suite does not prove the boundary is enforced. Three separate
security fixes in this repo shipped tests that verified structure while
missing the runtime decision point, and the gap was only found by
deliberately breaking the implementation:

- `RemoteHandleCloser` emptied its set instead of holding a terminal
  state, so a handle tracked after release was orphaned. Counting
  assignments passed; the ownership decision was untested.
- The agent tool-message boundary wrapped output correctly, but the
  production call sites could feed raw output again with every envelope
  test still green. Only a wiring guard plus mutation caught it.
- The Team guest pairing gate was invisible to tests that only counted
  `hasPaired` assignments. Extracting `PairingGate` as a pure function
  made the boundary testable and the mutation detectable.

### Required demonstration

unsafe mutation → observable behavioral failure

not merely: implementation structure → test passes.

### Scope

Applies to security boundaries, trust boundaries, authorization gates,
lifecycle safety, sensitive-data handling, and any other invariant whose
accidental removal could silently reintroduce a vulnerability.

## Git Rules
- DMG files must NEVER be in git (use .gitignore)
- Releases are uploaded to GitHub Releases only
- One commit per logical change, not per file
- **⚠️ Ask before committing — NEVER commit without explicit user permission**
