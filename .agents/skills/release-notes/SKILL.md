# Release Notes Style Guide

## Purpose

Define the standard for Bonk release notes, appcast descriptions, GitHub Release bodies, and other user-facing release metadata.

## Language

- Write all new release notes in **English**.
- Keep terminology consistent with the product UI and codebase.
- Do not translate technical identifiers that are clearer in their original form: `SFTP`, `SSH`, `Zmodem`, `logfmt`, `JSON`, `PTY`, `SwiftData`, etc.

## Tone

Use a concise, factual, professional changelog style.

Release notes should describe **what changed**, not advertise how impressive the implementation is.

### Never use hype language

Avoid words and phrases such as:

- ultimate
- S-tier
- P0 / P1 / P2 unless it is an internal engineering document
- true / truly / fully / completely when they add no factual information
- massive / huge / dramatic / major unless objectively necessary
- best-in-class
- breakthrough
- next-generation
- production-grade
- bulletproof
- zero-latency
- extreme performance
- perfect
- flawless
- "finally" or similar self-congratulatory wording

Do not claim that something is "fixed for good", "fully solved", or "actually works". State the concrete behavior instead.

## Scope

Each release note should cover the delta from the **previous release to the current release**. Do not rewrite the entire product history.

Prioritize:

1. New user-facing features.
2. User-visible fixes.
3. Meaningful behavior or configuration changes.
4. Important performance or reliability improvements.
5. Relevant cleanup only when it affects behavior, maintenance, or binary/runtime size.

Do not list internal refactors, file splits, class renames, or implementation details unless they materially affect users.

## Format

Prefer 3–6 short bullets. Group related changes when possible.

Use simple headings only when useful:

```markdown
## New
- ...

## Fixed
- ...
```

For small releases, a single `## Changes` section is preferred.

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
```

## Technical detail

Technical detail is welcome when it helps users understand the change, but keep it compact.

Good:

- `per-host` profiles
- snapshot isolation
- `logfmt` / JSON matching
- Zmodem enable/disable setting
- deterministic degraded-mode sampling

Avoid implementation inventories such as listing every new Swift file or every internal type.

## Version-to-version rule

When preparing release notes:

1. Identify the previous released version.
2. Compare the previous release with the current release.
3. Extract only meaningful changes introduced in that interval.
4. Remove duplicates and implementation-only noise.
5. Write the result in concise English.
6. Keep the same wording across `appcast.xml` and the GitHub Release body.

## Release metadata

When updating a release:

- Keep version numbers, build numbers, asset names, signatures, and download URLs unchanged unless the build itself changed.
- Do not regenerate or alter Sparkle signatures merely to change release text.
- Do not change existing historical release notes unless explicitly requested.
- The current release description should match the concise English release notes standard above.

## Final check

Before publishing, verify:

- English only for the new release text.
- No hype or self-congratulatory claims.
- No `true`, `ultimate`, `S-tier`, `P0`, or similar marketing language unless technically necessary.
- Describes the previous-to-current version delta.
- New features and fixes are both represented when applicable.
- 3–6 concise bullets unless the release genuinely needs more.
- `appcast.xml` and GitHub Release text use the same release-note wording.
