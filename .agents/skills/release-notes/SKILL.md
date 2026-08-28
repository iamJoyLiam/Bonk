# Release Notes Style Guide

## Purpose

Define the standard for Bonk release notes, appcast descriptions, GitHub Release bodies, and other user-facing release metadata. This Skill permanently documents the release-note rules so future releases remain consistent.

## Canonical Reference

**`2026.2.5` is the current canonical style reference.** All releases from `2026.2.0` through `2026.2.4` have been standardized to match its wording. Treat `2026.2.5` as the template for future releases unless explicitly superseded.

Example canonical note (2026.2.5):

```markdown
## Changes

- Added per-host log highlighting profiles with isolated snapshots between terminal tabs.
- Fixed `logfmt` level preview matching and duplicate IP/logfmt highlighting; legacy `Default` profiles are migrated automatically.
- Simplified log highlighting settings and consolidated color configuration.
- Added a setting to enable or disable Zmodem transfers in SFTP windows.
- Removed unused highlight components and made degraded-mode sampling deterministic.
```

## Language — English Only

- Write **all** release notes in **English only**.
- Do not leave Chinese text in:
  - GitHub Release bodies
  - `appcast.xml` descriptions
  - Release notes
  - Appcast descriptions
  - Any future release-note templates
- Keep terminology consistent with the product UI and codebase.
- Do not translate technical identifiers that are clearer in their original form: `SSH`, `SFTP`, `Zmodem`, `PTY`, `logfmt`, `JSON`, `SwiftData`, etc.

## Tone — Concise, Factual, Professional

Use a concise, factual, professional changelog style. Describe **what changed**, not how impressive the implementation is.

### Never use hype or self-congratulatory wording

Avoid words and phrases such as (unless objectively required by technical meaning):

- true / truly
- ultimate
- S-tier
- P0 / P1 / P2
- fully / completely
- perfect / flawless
- massive / huge / dramatic / major
- breakthrough
- next-generation
- production-grade
- bulletproof
- extreme performance
- zero-latency
- finally
- completely solved / permanently fixed
- actually works
- revolutionary
- best-in-class

Also avoid: `completely`, `fully`, `truly`, `ultimate`, `massive`, `huge`, `breakthrough`, `next-generation`, `bulletproof`, `extreme performance`, `zero-latency`, `finally`, `actually works`, `revolutionary` unless technically necessary.

Do not claim that something is "fixed for good", "fully solved", or "actually works". State the concrete behavior instead (e.g., "Fixed SSH sessions becoming unresponsive after idle connections.").

## Scope — Version-to-Version Delta

Each release must describe **only the meaningful changes introduced since the previous release**.

**Release N = changes from Release N-1 → Release N.** Do not rewrite the entire product history into every release. Do not move later features backward into earlier releases. Do not invent features.

Example:

```
2026.2.5 = changes introduced after 2026.2.4
2026.2.4 = changes introduced after 2026.2.3
2026.2.3 = changes introduced after 2026.2.2
```

Prioritize:

1. New user-facing features
2. User-visible fixes
3. Important behavior changes
4. Meaningful performance / reliability improvements
5. Relevant cleanup only when it affects behavior, maintenance, or binary/runtime size

Do not include internal implementation details unless they are useful to users.

Avoid listing:

- Swift file names
- class names
- internal refactors
- architecture details
- implementation inventories
- code cleanup that has no user-visible impact
- file splits, class renames, or internal type inventories

## Format — Simple, 3–6 Bullets

Prefer:

```markdown
## Changes

- ...
- ...
- ...
```

- Usually keep it to **3–6 concise bullets** by default. Group related changes when possible.
- For small releases, a single `## Changes` section is preferred. Use `## New` / `## Fixed` only when useful.
- Keep the presentation simple.

Do not create unnecessary sections such as:

```
Ultimate Improvements
Major Architecture Upgrade
Performance Revolution
```

### Good examples

```markdown
## Changes
- Added per-host log highlighting profiles and isolated snapshots between terminal tabs.
- Fixed `logfmt` level preview matching and duplicate IP/logfmt highlighting.
- Added automatic migration for legacy `Default` log profiles.
- Added a setting to enable Zmodem transfers in SFTP windows.
- Simplified log highlighting settings and removed unused highlight components.
```

```markdown
## Changes
- Improved SFTP transfer throughput and reconnect behavior.
- Fixed terminal sessions becoming unresponsive after idle SSH connections.
- Fixed Swift 6 concurrency warnings in SerialPort.
```

### Bad examples

```markdown
- Ultimate log coloring architecture with true per-host isolation.
- P0 S-tier performance improvements.
- Completely solved all tab interference problems.
- Real zero-copy extreme-speed SFTP engine.
- Production-grade bulletproof next-generation breakthrough.
```

## Technical Detail

Technical detail is welcome when it helps users understand the change, but keep it compact.

Good (concise, user-relevant):

- `per-host` profiles
- snapshot isolation
- `logfmt` / JSON matching
- Zmodem enable/disable setting
- deterministic degraded-mode sampling
- Bonjour discovery + IP/PIN pairing

Avoid implementation inventories such as listing every new Swift file or every internal type.

## Version-to-Version Rule

When preparing release notes:

1. Identify the previous released version.
2. Compare the previous release with the current release (e.g., `git log v2026.2.3..v2026.2.4`).
3. Extract only meaningful changes introduced in that interval.
4. Remove duplicates and implementation-only noise (file names, class names, refactors).
5. Write the result in concise English (3–6 bullets).
6. Keep the **same wording** across `appcast.xml` and the GitHub Release body.

## GitHub Releases and appcast.xml Consistency

- Update the GitHub Release body and the corresponding `appcast.xml` `<description>` for the same version with **identical wording**.
- Both must use the concise English style above (header `## Changes` + bullets).
- Never leave Chinese text in either location.
- `2026.2.5` is already canonical and should not be unnecessarily rewritten; keep its wording stable as the reference.

## Release Metadata Preservation

When updating a release description, **only change release-note text**. Do NOT modify:

- version numbers (`sparkle:version`, `sparkle:shortVersionString`, tag `v2026.x.x`)
- build numbers (`CURRENT_PROJECT_VERSION`)
- release dates (`pubDate`, GitHub `createdAt`)
- DMG filenames
- download URLs
- asset sizes (`length`, `enclosure length`)
- Sparkle signatures (`sparkle:edSignature`)
- enclosure metadata (`type`, `sparkle:os`, `sparkle:cpuAffinity`)

Do not regenerate or alter Sparkle signatures merely to change release text. Do not change existing historical release notes unless explicitly requested.

## Historical Accuracy

- Do not invent features. Use the actual changes that belong to each version.
- Prioritize new user-facing features, then fixes, then behavior changes, then meaningful performance improvements.
- Do not include internal refactors or code cleanup without user-visible impact.
- Each release's notes must reflect its own delta, not the product's entire history.

## Final Verification

Before publishing or after editing historical releases, verify:

1. All GitHub Release bodies from the edited range read as concise English (no Chinese).
2. All corresponding `appcast.xml` descriptions match the GitHub bodies wording.
3. No hype / self-congratulatory wording remains.
4. Each release describes its own version-to-version delta (not full history, not moved features).
5. GitHub Release and appcast wording are consistent.
6. `v2026.2.5` remains unchanged as the canonical reference.
7. No asset, signature, URL, version, or build metadata was changed.
8. Format is `## Changes` with 3–6 bullets, no unnecessary sections.
9. Technical terms (`SSH`, `SFTP`, `Zmodem`, `PTY`, `logfmt`, `JSON`, `SwiftData`) remain unchanged.

## References

- Canonical release: `2026.2.5` (`v2026.2.5`) — `appcast.xml` and GitHub Release body
- Related Skill: `bonk-release` — overall macOS release process (version bump, build, DMG, signing, appcast, GitHub Release)
- Sparkle docs: `appcast.xml` `<description>` uses Markdown (Sparkle ≥ 2.9, macOS 12+)
