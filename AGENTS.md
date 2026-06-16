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

**铁律：整个发布流程必须一次性完成，只产生 1 次 git commit。不允许分步提交。**

### 步骤（严格按顺序，中间不能停）

1. 确认所有功能代码已提交，git 干净
2. `project.pbxproj` bump 两个版本号（各有 2 处，共 4 处替换）：
   - `MARKETING_VERSION`（如 `2026.0.6`）
   - `CURRENT_PROJECT_VERSION`（如 `202606`，Sparkle 用此判断更新）
3. `xcodebuild -configuration Release clean build`（arm64）→ 确认无 `.dylib`、无嵌套 app → 拷贝到 `/tmp`
4. `xcodebuild -configuration Release build`（x86_64）→ 同上检查 → 拷贝到 `/tmp`
5. 创建 DMG（含 Applications 快捷方式）→ 签名
6. 更新 `appcast.xml`（版本号 + 签名 + length）
7. 创建/更新 GitHub Release，上传 DMG
8. **一次** `git add -A && git commit && git push`

### 关键注意事项

- **编译配置必须是 Release**，Debug 包含调试数据，不适合分发
- **DMG 必须包含 Applications 快捷方式**：
  ```
  mkdir /tmp/dmg && cp -R Bonk.app /tmp/dmg/ && ln -s /Applications /tmp/dmg/Applications
  hdiutil create -volname "Bonk" -srcfolder /tmp/dmg -ov -format UDZO output.dmg
  ```
- **编译前必须 clean**：不 clean 会产生 `Bonk.debug.dylib`（42MB）和嵌套 `Bonk.app`
- **检查产物**：确认 `Contents/MacOS/` 下无 `.dylib`，无嵌套 `Bonk.app`
- **appcast.xml 的 length** 必须和实际 DMG 文件大小一致
- **不要删除重建 GitHub Release**：一旦发布，只追加 assets，不删除重建（会导致签名失效）
- **sign_update 签名**对应的是 Release 编译的 DMG，不是 Debug
- **appcast.xml 的 length** 必须和实际 DMG 文件大小一致
- **如果回退了 release commit**（git reset --soft），GitHub Release 也要删除重创

### Sparkle sign_update 路径
```
DerivedData/Bonk-.../SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
```

## Git Rules
- DMG files must NEVER be in git (use .gitignore)
- Releases are uploaded to GitHub Releases only
- One commit per logical change, not per file
- Ask before committing
- Release commit 包含：版本 bump + appcast.xml 更新，单次提交
