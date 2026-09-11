# Bonk

> 一款精致的 macOS 原生 SSH 终端客户端，为日常服务器工作而生。

[English README](README.md) · [Releases 发布页](https://github.com/iamJoyLiam/Bonk/releases) · [主页](https://bonk-terminal.pages.dev/)

![macOS](https://img.shields.io/badge/macOS-15%2B-black) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![Platform](https://img.shields.io/badge/Platform-macOS-lightgrey) ![Release](https://img.shields.io/github/v/release/iamJoyLiam/Bonk)

Bonk 是一款快速、功能丰富的 macOS SSH 终端。它把原生 SwiftUI 界面与完全可自定义的 AppKit 工具栏结合在一起，并内置了日常服务器工作所需的一切：SFTP 浏览、端口转发、带 Agent 模式的 AI 助手、Warp 风格的行内补全、代码片段、工作区，以及 Quake 风格的下拉终端。

## 为什么选择 Bonk？

- **原生，不是 Electron。** 真正的 macOS 公民——快速、轻量、贴合系统风格。
- **一个窗口搞定一切。** 连接、浏览文件、转发端口、问 AI——不必在多个应用之间来回切换。
- **按你的习惯定制。** 拖拽式工具栏、主题引擎、可配置快捷键、可保存的工作区。
- **隐私友好的 AI。** 自带 API Key，也支持本地 Ollama。
- **稳定在线。** 自动重连，可从睡眠唤醒与网络切换中恢复，认证失败时给出易懂的错误说明。

## ✨ 功能特性

### 🖥 终端与连接

| | |
| --- | --- |
| SSH 终端 | 标签页 + 分屏，支持 arm64 与 x86_64 |
| SFTP | 独立窗口浏览器，支持拖拽上传 |
| 端口转发 | 本地、远程、动态（SOCKS5） |
| 串口 | 连接 `/dev/tty.*` 设备 |
| 跳板机 | 通过堡垒机链式连接 |
| 安全 | 主机密钥校验、Secure Enclave P256 密钥、凭据钥匙串 |
| 速度 | 原生优先的混合引擎，约 1 秒建连，SFTP 流水线传输 |
| 可靠性 | 自动重连、唤醒/网络恢复、认证重试与清晰报错 |
| 扩展 | Zmodem 传输、SSH 配置导入、Tabby 导入 |

### ⌨️ 行内补全

- Warp 风格的灰字提示，本地即时层 + AI 通道，按你的使用习惯排序学习
- 原生候选弹窗，一键接受

### 🤖 AI 助手

- 支持 **GitHub Copilot、Claude、OpenAI、Gemini、OpenRouter、OpenCode Zen、Ollama** 及任意 OpenAI 兼容接口
- **Agent 模式**——带权限模型与防循环保护的分步任务执行，支持推理流与渲染后的命令输出
- 生成和解释命令、诊断报错输出，还能按需通过 SSH 操作已保存的主机
- 自定义提供商配置；你的 Key、你的数据——无云端中转

### ⚡ 效率工具

- **自定义工具栏** —— 拖拽排序、右键自定义、布局自动保存
- **代码片段与命令历史** —— 告别反复敲同一行命令
- **工作区** —— 保存和恢复多会话布局
- **广播输入** —— 一次输入，同步到所有分屏
- **Quake 终端** —— 全局热键呼出下拉终端（⌘`）
- **主题** —— 深色、浅色、Dracula、Nord、Solarized，以及自定义主题
- **会话录制** —— 将分屏录制为 asciicast v2，随时回放
- **工作区模板与专注模式** —— 一键布局，免打扰专注
- **服务器监控** —— 每个标签页的实时资源状态，同步显示在工具栏
- **日志高亮配置** —— 按主机区分，支持 logfmt/JSON 匹配与真彩色取色器
- **轻松导入** —— SSH 配置变动自动导入，支持 Tabby 导入
- **iCloud 同步与 Sparkle 自动更新**

### 👥 团队共享

- 通过 Bonjour 发现 + IP/PIN 配对，在局域网内共享主机
- 访客窗口，带发言权控制与在线状态

## 📸 截图

_敬请期待。_

## 🚀 快速开始

1. 从 [Releases 发布页](https://github.com/iamJoyLiam/Bonk/releases) 下载最新 DMG，把 **Bonk** 拖入"应用程序"。
2. 启动 Bonk，添加主机（名称、地址、端口）并连接。
3. 可选：在 **设置 → AI** 中配置 AI 提供商，解锁助手。

- 需要 **macOS 15+** · 支持 Apple Silicon 与 Intel
- 应用已签名，通过 Sparkle 自动更新

## ⌨️ 快捷键

| 操作 | 快捷键 |
| --- | --- |
| Quake 下拉终端 | `⌘`` |
| 检查更新 | `⌥⌘U` |
| 工作区 | `⌥⌘S` |

其余大部分快捷键（新建终端、分屏、SFTP、AI、查找等）都可在 **设置 → 键盘** 中自定义。

## 🛠 技术栈

| 分层 | 技术 |
| --- | --- |
| 界面 | SwiftUI + AppKit（Swift 6） |
| 终端渲染 | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) |
| SSH | 混合引擎——原生优先，OpenSSH 兜底 |
| 存储 | SwiftData |
| 更新 | Sparkle |
| AI | OpenAI 兼容接口、Copilot、Claude、Gemini、Ollama 等 |

## 🧑‍💻 开发

需要 Xcode 26。支持 macOS 15+。

```bash
git clone https://github.com/iamJoyLiam/Bonk.git
cd Bonk
open Bonk.xcodeproj
```

## 🏗 架构

主窗口是 AppKit 自持的 `NSSplitViewController` 壳层，内部托管 SwiftUI 内容——保证完全可自定义的 `NSToolbar` 稳定运行，避免与 SwiftUI 的窗口工具栏所有权冲突。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request。有功能想法或 Bug，请先开 Issue 讨论。

## 📄 许可证

[MIT](LICENSE)
