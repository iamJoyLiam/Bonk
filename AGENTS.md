# Bonk Project Guidelines

## SwiftData Production Store Safety

The store holds every host, credential and preference the user has. On
2026-09-23 and again on 2026-09-29 it was found with all fifteen entity tables
DROPped and every host gone.

What happened, established from the database itself: at 22:53:59 the store held
only CoreData's bookkeeping tables plus one stray `ZAPIREQUESTMODEL` — a table
present in no commit and on no branch. A scratch `ModelContainer` had been built
from a schema listing that model and none of the production entities, and
because it specified neither `isStoredInMemoryOnly` nor an explicit `url`, it
defaulted to the production file. SwiftData's migration then dropped every table
outside the schema it was handed.

Only the developer's machine was affected: the destructive code never shipped.

**These are rules, not advice.**

1. **Never construct a `ModelContainer` outside `BonkStore`.**
   `makeProduction()` is the only way to reach the real store. `makeTest(at:)`
   requires an explicit URL and cannot name the production path.
   `makeInMemory()` for throwaway state. Enforced by
   `StoreConfigurationSafetyTests` — a container built anywhere else fails the
   build, including in `BonkApp.swift`.

2. **A test container must be verified by reading its file, not its container.**
   A container that ignored its URL still returns a working object and passes
   every in-container assertion. Use `BonkStore.hostRows(in:)`. Do not assert on
   the live store from a test: with the bug live, running the assertion is itself
   the write.

3. **Production schema changes go through `BonkStore.Schema`.**
   Adding an entity: register it in the schema literal, in `entityNames`, and in
   `StoreSchemaContract.baselineEntityNames`. Adding is safe.

4. **Removing an entity requires explicit approval.**
   It drops the table and every row. Record it in
   `BonkStore.Schema.approvedEntityDeletions` with a reason, and remove it from
   both other lists. Three edits, deliberately.

5. **Destructive test code must not compile into production.**
   No `/tmp` trigger files, no result files, no hand-driven UI harnesses, no
   hardcoded credentials. Test-only behaviour belongs behind `#if DEBUG` in the
   same file, or in `BonkTests`. Enforced by
   `StoreConfigurationSafetyTests`.

6. **A failed read is never zero records.**
   `SQLITE_BUSY`, a missing table and an empty table are three different facts.
   Anything that decides "no data" must distinguish them, or a safety net will
   quietly do nothing exactly when it is needed. See
   `StoreBackupManager.snapshotHostCount`.

7. **Never mutate a working guard to test it.**
   Adversarial mutation is required (see below) and the mutation that matters
   most — dropping `makeTest`'s `url:` — writes to the real store. Run it, then
   verify the production row count and clean up any residue. Do not skip the
   cleanup; do not assume the mutation was harmless.

## Database (SwiftData) Rules

### Schema Changes
- **NEVER** change `storeName` — always use default (no explicit name). Changing it creates a new empty database.
- **NEVER** modify existing model properties (rename, change type, delete). Breaks migration.
- **ONLY** add new models or add optional properties to existing models.
- **NEVER** use destructive migration fallback. Fatal error on migration failure.
- **NEVER** use `String?` for entity references. Use `@Relationship`.
- **NEVER** open a second `ModelContainer` against the live store, especially
  with a partial `Schema`. SwiftData migration DROPs every table outside the
  opened model's schema — v2026.4.3 and v2026.9.x each wiped all hosts this way.
  Always read through `BonkApp.sharedModelContainer`; tests use in-memory stores
  or a `BonkStore.makeTest` temporary directory only.

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

## Test Execution Evidence

A test that did not run is not a passing test. `TEST SUCCEEDED` with zero
executed tests is not evidence.

Any verification of a security or lifecycle boundary must state the number of
tests actually executed, and `requested == executed` must hold. A filtered test
run that matches zero tests must be treated as invalid verification, regardless
of process exit status.

For Swift Testing, `xcodebuild -only-testing` requires the test identifier to
include `()`. Omitting `()` can silently match zero tests while returning
`TEST SUCCEEDED` and exit code 0.

Verification scripts MUST fail closed when the requested test count is non-zero
and the executed test count is zero, or when requested and executed counts
differ.

### Skipped is not executed

For any security finding, "green" is not a valid verification result unless
all four hold:

    requested == executed    failed == 0    skipped == 0    crash == 0

A skipped designated gate is **NOT VERIFIED**, and the skip condition must be
named in the finding's status. `10 skipped` alongside a green suite does not
mean the suite is fine; it means ten tests proved nothing, and if any of them
is a security gate then the finding it guards is unverified.

This bit during the B-02 review. Its designated gate was
`SFTPMatrixLocalTests.testServiceHostKeyMismatchDoesNotFallBack`, which opens
with `try XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")`. With no
server on :2222 the test never ran — so the gate had never executed, while
every full-target report carried `skipped=10` that was being read as ordinary
baseline noise. The assertion had been inverted correctly all along; the test
simply never ran. Correct-but-unrun is not weaker than no test, because it
discharges the obligation to look.

A skipped gate blocks **verification**, not **commits**. Work that does not
touch the gated boundary may still be committed, provided the finding's status
records the gate as NOT VERIFIED with its skip condition. Conflating the two
turns a missing integration environment into a lock on unrelated work; keeping
them apart lets the gap stay visible without blocking everything.

Report the split explicitly, in this shape:

    B-02 policy    VERIFIED      mutation-proven, runnable, 0 skips
    B-02 end-to-end NOT VERIFIED  bench-linux absent (tcp:2222 closed)

### Why this is a rule and not advice

Adopted 2026-10-05 after this exact failure occurred twice in one session while
verifying a command-deadline boundary. A filtered run was reported as "passes in
isolation" on the strength of `TEST SUCCEEDED`, when it had executed nothing.
That produced a wrong conclusion, which then produced a wrong hypothesis about
the cause, which survived two rounds of investigation before being caught.

It is the same class of error as the ones above, arriving from a different
direction: not a test that passes while the guard is broken, but a *verification
step* that passes while nothing is being verified. A green suite and a green
verification command are the same claim, and both need the same evidence.

Two consequences worth internalizing:

- Exit status is not evidence. Neither is "no failures reported".
- A conclusion drawn from a filtered run is only as good as the proof that the
  filter selected what you meant. Check the executed count before reading the
  result, not after.

## Agent Capability Boundary

An agent may generate code freely. An agent may NOT freely acquire
production capabilities.

Code that only ever runs in a test is not automatically safe, because
the resources it touches — SwiftData stores, SQLite files, the
filesystem, Keychain, UserDefaults, the network, real accounts — do not
know they are being tested. "The test passed" and "the test was safe"
are different claims, and this repo has now been damaged by conflating
them twice.

The same shape as the generative → decision → policy → deterministic
runtime layering the rest of the app follows: generation is unbounded,
acquisition of a production resource is not.

Before running anything that opens a store, writes a file outside a
temp directory, or reads a secret, ask which process will own the
resource when it runs.

## Git Rules
- DMG files must NEVER be in git (use .gitignore)
- Releases are uploaded to GitHub Releases only
- One commit per logical change, not per file
- **⚠️ Ask before committing — NEVER commit without explicit user permission**
