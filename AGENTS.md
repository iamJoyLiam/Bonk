# Bonk Project Guidelines

## Database (SwiftData) Rules

### Schema Changes
- **NEVER** change `storeName` — always use default (no explicit name). Changing it creates a new empty database.
- **NEVER** modify existing model properties (rename, change type, delete). Breaks migration.
- **ONLY** add new models or add optional properties to existing models.
- **NEVER** use destructive migration fallback. Fatal error on migration failure.
- **NEVER** use `String?` for entity references. Use `@Relationship`.

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
2. Version bump in project.pbxproj
3. Clean build arm64 + x86_64
4. DMG created in /tmp (NEVER in git)
5. Sign with Sparkle sign_update
6. Upload both DMGs to GitHub Release
7. Update appcast.xml with both architecture entries
8. Single commit for release
9. Push

## Git Rules
- DMG files must NEVER be in git (use .gitignore)
- Releases are uploaded to GitHub Releases only
- One commit per logical change, not per file
- Ask before committing
