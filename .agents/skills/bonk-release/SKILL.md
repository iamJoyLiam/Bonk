# Bonk Release Skill

**名称：** bonk-release
**描述：** Bonk macOS 应用打包发布流程

**前置条件：** 所有命令在仓库根目录（Bonk.xcodeproj 所在目录）执行。

---

## 何时使用

当用户要求发布新版本时使用此 skill。

---

## 发布流程

### 步骤 1：检查版本号

```bash
grep "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" Bonk.xcodeproj/project.pbxproj | head -4
```

**规则：**
- `MARKETING_VERSION` = 用户可见版本（如 2026.1.2）
- `CURRENT_PROJECT_VERSION` = 内部版本号（如 2026102 = 年份+月份+补丁号拼接）
- **两个必须一起更新！** 这是最常犯的错误

### 步骤 2：更新版本号

```bash
# 替换版本号（示例：2026.1.2 -> 2026.1.3）
sed -i '' 's/MARKETING_VERSION = 2026.1.2;/MARKETING_VERSION = 2026.1.3;/g' Bonk.xcodeproj/project.pbxproj
sed -i '' 's/CURRENT_PROJECT_VERSION = 2026102;/CURRENT_PROJECT_VERSION = 2026103;/g' Bonk.xcodeproj/project.pbxproj
```

**⚠️ 关键提醒：** 必须同时更新 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`！
版本号规则：`MARKETING_VERSION` = `YEAR.MONTH.PATCH`（如 2026.1.2），`CURRENT_PROJECT_VERSION` = `YEAR+MONTH+PATCH` 拼接（如 2026.1.2 → 2026102）。

### 步骤 3：编译 arm64 Release

```bash
xcodebuild -scheme Bonk -configuration Release -derivedDataPath build clean build ARCHS=arm64 ONLY_ACTIVE_ARCH=NO 2>&1 | tail -5
```

产物固定输出到 `build/Build/Products/Release/Bonk.app`（-derivedDataPath 保证路径可预测）。

### 步骤 4：创建 arm64 DMG

```bash
rm -rf /tmp/dmg && mkdir -p /tmp/dmg && \
cp -R build/Build/Products/Release/Bonk.app /tmp/dmg/ && \
ln -s /Applications /tmp/dmg/Applications && \
hdiutil create -volname "Bonk" -srcfolder /tmp/dmg -ov -format UDZO -imagekey zlib-level=9 /tmp/Bonk-VERSION-arm64.dmg
```

**⚠️ 关键提醒：** DMG 必须包含 Applications 快捷方式！文件名带 `-arm64` 后缀。

### 步骤 5：编译 x86_64 Release

```bash
xcodebuild -scheme Bonk -configuration Release -derivedDataPath build build ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO 2>&1 | tail -5
```

### 步骤 6：创建 x86_64 DMG

```bash
rm -rf /tmp/dmg && mkdir -p /tmp/dmg && \
cp -R build/Build/Products/Release/Bonk.app /tmp/dmg/ && \
ln -s /Applications /tmp/dmg/Applications && \
hdiutil create -volname "Bonk" -srcfolder /tmp/dmg -ov -format UDZO -imagekey zlib-level=9 /tmp/Bonk-VERSION-x86_64.dmg
```

**⚠️ 关键提醒：** DMG 必须包含 Applications 快捷方式！

### 步骤 7：签名 DMG

```bash
# 签名 arm64
$(dirname $(xcode-select -p))/usr/local/bin/sign_update /tmp/Bonk-VERSION-arm64.dmg

# 签名 x86_64
$(dirname $(xcode-select -p))/usr/local/bin/sign_update /tmp/Bonk-VERSION-x86_64.dmg
```

> 注：`sign_update` 位于 Sparkle 仓库 `bin/`（需 `make` 编译生成），将其路径加入 PATH 或替换上方命令。

**输出示例：**
```
sparkle:edSignature="xxx" length="12345678"
```

**⚠️ 关键提醒：** 保存签名和长度，用于 appcast.xml！

### 步骤 8：更新 appcast.xml

在 `appcast.xml` 中添加新版本（替换 VERSION / VERSION_CODE / DATE / LENGTH / SIGNATURE）：

**⚠️ 更新说明格式（Sparkle ≥ 2.9）：** 使用 **Markdown** 而非 HTML。Sparkle 2.9+
自动渲染 Markdown 更新说明（macOS 12+）。`<description>` CDATA 内直接写 Markdown：

```xml
<item>
    <title>VERSION</title>
    <pubDate>DATE</pubDate>
    <sparkle:version>VERSION_CODE</sparkle:version>
    <sparkle:shortVersionString>VERSION</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
    <description><![CDATA[
## Changes
- Added feature 1
- Fixed behavior 2
    ]]></description>
    <enclosure
        url="https://github.com/iamJoyLiam/Bonk/releases/download/VERSION/Bonk-VERSION-arm64.dmg"
        length="LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="SIGNATURE"
        sparkle:os="macos"
        sparkle:cpuAffinity="arm64"
    />
    <enclosure
        url="https://github.com/iamJoyLiam/Bonk/releases/download/VERSION/Bonk-VERSION-x86_64.dmg"
        length="LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="SIGNATURE"
        sparkle:os="macos"
        sparkle:cpuAffinity="x86_64"
    />
</item>
```

**⚠️ 关键提醒：**
- URL 必须使用 `https://github.com/iamJoyLiam/Bonk/releases/download/` 格式
- `length` 和 `sparkle:edSignature` 必须与签名输出一致
- `sparkle:minimumSystemVersion` 必须与 `MACOSX_DEPLOYMENT_TARGET`（当前 15.0）一致，发布前先 grep 确认，不要沿用旧值
- 更新说明用 Markdown，不要用 HTML 标签

> 待办（未启用）：Sparkle 2.9 feed 签名（SURequireSignedFeed + SUVerifyUpdateBeforeExtraction）。
> 需要生成 feed 公钥并启用 Info.plist 配置；当前 Sparkle bin 无独立 feed 签名工具，启用前先确认签名流程。

### 步骤 9：创建 GitHub Release

```bash
gh release create vVERSION /tmp/Bonk-VERSION-arm64.dmg /tmp/Bonk-VERSION-x86_64.dmg \
  --title "Bonk vVERSION" \
  --latest \
  --notes-file /tmp/release_notes.md
```

> **Release notes must be English-only, concise, and factual.** See `.agents/skills/release-notes/SKILL.md` (canonical reference: `2026.2.5`). Use `## Changes` + 3–6 bullets, describe the delta since the previous release, avoid hype language and implementation details, and keep `appcast.xml` and GitHub Release bodies identical. Do not modify version/build numbers, dates, URLs, sizes, or Sparkle signatures when only updating notes.

**⚠️ 关键提醒：** 使用 `--latest` 标记为最新版本！

### 步骤 10：提交并推送

```bash
# 合并成一个 release commit
git add -A && git commit -m "release: Bonk vVERSION"

# 创建 tag（与 gh release 名一致，带 v 前缀）
git tag vVERSION

# 推送
git push origin main && git push origin vVERSION
```

---

## 常见错误

### 错误 1：版本号不一致

**现象：** 用户看到 "2026.1.2 (2026103)" 而不是 "2026.1.2 (2026102)"

**原因：** `CURRENT_PROJECT_VERSION` 没有更新

**解决：** 必须同时更新 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`

### 错误 2：tag 指向错误

**现象：** tag 指向旧的 commit

**解决：**
```bash
git tag -d vVERSION
git push origin :refs/tags/vVERSION
git tag vVERSION
git push origin vVERSION
```

### 错误 3：GitHub Release 是 Draft

**现象：** Release 显示为 Draft 状态

**解决：**
```bash
gh release edit vVERSION --latest
```

### 错误 4：签名不匹配

**现象：** Sparkle 下载失败

**原因：** DMG 签名与 appcast.xml 中的签名不一致

**解决：** 重新签名 DMG 并更新 appcast.xml

### 错误 5：多个提交

**现象：** 有多个提交而不是一个 release commit

**解决：**
```bash
git reset --soft HEAD~N
git commit -m "release: Bonk vVERSION"
git push origin main --force
```

### 错误 6：DMG 版本号错误

**现象：** 用户下载的 DMG 版本号与 appcast.xml 不一致

**原因：** DMG 是用旧版本编译的

**解决：** 重新编译、创建 DMG、签名、更新 appcast.xml、更新 GitHub Release

### 错误 7：CHANGELOG.md 被提交

**现象：** CHANGELOG.md 被提交到仓库

**解决：** 删除 CHANGELOG.md，添加到 .gitignore

### 错误 8：AGENTS.md 被提交

**现象：** AGENTS.md 被提交到仓库

**解决：** 删除 AGENTS.md（已加入 .gitignore）

### 错误 9：minimumSystemVersion 错误

**现象：** 用户在 macOS 15 上无法更新 / 旧版本系统提示版本不符

**原因：** appcast.xml 的 `sparkle:minimumSystemVersion` 与 `MACOSX_DEPLOYMENT_TARGET` 不一致

**解决：** 发布前 grep 两个值并保持同步（当前为 15.0）

---

## 版本号规则

- `MARKETING_VERSION`: 用户可见版本（如 2026.1.2）
- `CURRENT_PROJECT_VERSION`: 内部版本号（如 2026102）
- 格式：`MARKETING_VERSION` = `YEAR.MONTH.PATCH`（如 2026.1.2）
- 格式：`CURRENT_PROJECT_VERSION` = `YEAR + MONTH + PATCH` 拼接（如 2026 + 1 + 02 = 2026102）

---

## 检查清单

发布前检查：

- [ ] 所有功能代码已提交
- [ ] `MARKETING_VERSION` 已更新
- [ ] `CURRENT_PROJECT_VERSION` 已更新
- [ ] arm64 编译成功
- [ ] x86_64 编译成功
- [ ] arm64 DMG 创建成功（含 Applications 快捷方式）
- [ ] x86_64 DMG 创建成功（含 Applications 快捷方式）
- [ ] DMG 签名成功
- [ ] appcast.xml 已更新（签名、长度、minimumSystemVersion）
- [ ] GitHub Release 创建成功（--latest）
- [ ] Tag 创建成功
- [ ] 提交并推送成功
- [ ] 验证版本号一致（编译后的 Info.plist、project.pbxproj、appcast.xml）

---

**Why:** 统一发布流程，避免重复踩坑
**How to apply:** 发布新版本时按此流程执行
