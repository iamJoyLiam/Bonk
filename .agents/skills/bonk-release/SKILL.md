# Bonk Release Skill

**名称：** bonk-release
**描述：** Bonk macOS 应用打包发布流程

**前置条件：** 所有命令在仓库根目录（Bonk.xcodeproj 所在目录）执行。

---

## 何时使用

当用户要求发布新版本时使用此 skill。

---

## 流程（3 步，中间那步是脚本，不许手拆）

### 步骤 1：版本号 + 发布说明（人工准备）

```bash
grep "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" Bonk.xcodeproj/project.pbxproj
```

- `MARKETING_VERSION` = 用户可见版本（如 `2026.4.5`），`CURRENT_PROJECT_VERSION` = 内部版本号。
  换算：`YEAR + MONTH(不补零) + PATCH(补足3位)`，如 `2026.4.5 → 20264005`（对照历史：`2026.4.4 → 20264004`）。
- **两个必须一起更新！** 只看主 target（`JoyLiam.Bonk`），别被 `BonkTests` 的 `1.0` 误导。
- 按 `.agents/skills/release-notes/SKILL.md` 写英文发布说明，存到 `/tmp/release_notes_<VERSION去点>.md`
  （如 `/tmp/release_notes_202645.md`）。该文件同时用于 `appcast.xml` 和 GitHub Release 正文。

### 步骤 2：跑脚本（编译→DMG→签名→验签→appcast→Release→验证，一气呵成）

```bash
./scripts/release.sh VERSION
# 自定义 notes 路径：./scripts/release.sh VERSION --notes-file /tmp/release_notes.md
```

脚本内已硬门禁：版本号不一致、build 号不递增、notes 含中文、签名无效、DMG 被改动、
Release 已存在、发布后非 Latest / 下载字节对不上——任一失败即 `FAIL` 退出，
**没有 `PASS` 就是没发布完，不许收工。**

### 步骤 3：脚本 PASS 后，一次提交 + tag + 推送

```bash
git add -A && git commit -m "release: Bonk vVERSION"
git tag vVERSION
git push origin main && git push origin vVERSION
```

---

## 脚本 FAIL 了怎么办

1. 看 `FAIL:` 那一行，按阶段修（`P0` 是准备工作没做对，`P5/P6` 是签名问题，`P9` 是 GitHub 侧问题）。
2. 修完直接重跑脚本。重跑安全，唯一例外：如果 `appcast.xml` 已被写入（`P7` 之后失败），
   重跑前先删掉对应 `<item>` 段（有备份：`/tmp/appcast.xml.bak-VERSION`）。
3. tag 指错 commit（`gh release create` 在 tag 不存在时自动建的 tag 可能指向旧 main）：
```bash
git tag -d vVERSION
git push origin :refs/tags/vVERSION
git tag vVERSION
git push origin vVERSION
```

---

**Why:** 2026.4.4 血泪教训——11 步手操清单做到第 8 步就停了，Release 根本没建，
`v2026.4.3` 继续挂着 Latest。清单靠自觉没用，脚本退码才有用。
**How to apply:** 发布时只调脚本，不许把步骤拆开手跑。
