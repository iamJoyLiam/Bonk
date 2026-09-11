# Bonk

> A polished, native macOS SSH terminal client for daily server work.

[中文文档](README.zh-CN.md) · [Releases](https://github.com/iamJoyLiam/Bonk/releases) · [Homepage](https://bonk-terminal.pages.dev/)

![macOS](https://img.shields.io/badge/macOS-15%2B-black) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![Platform](https://img.shields.io/badge/Platform-macOS-lightgrey) ![Release](https://img.shields.io/github/v/release/iamJoyLiam/Bonk)

Bonk is a fast, feature-rich SSH terminal for macOS. It pairs a native SwiftUI interface with a fully customizable AppKit toolbar, and bundles everything you reach for every day: SFTP browsing, port forwarding, an AI assistant with agent mode, Warp-style inline suggestions, snippets, workspaces, and a Quake-style drop-down terminal.

## Why Bonk?

- **Native, not Electron.** A real macOS citizen — fast, lightweight, and styled for the system.
- **Everything in one window.** Connect, browse files, forward ports, ask AI for help — without juggling multiple apps.
- **Customizable to your taste.** Drag-and-drop toolbar, theme engine, configurable shortcuts, saved workspaces.
- **Privacy-friendly AI.** Bring your own API key; local Ollama supported.
- **Stays connected.** Automatic reconnect with wake and network-change healing, plus plain-language explanations when authentication fails.

## ✨ Features

### 🖥 Terminal & Connection

| | |
| --- | --- |
| SSH terminal | Tabs + split panes, arm64 & x86_64 |
| SFTP | Dedicated browser window with drag-and-drop uploads |
| Port forwarding | Local, remote, dynamic (SOCKS5) |
| Serial port | Connect to `/dev/tty.*` devices |
| Jump hosts | Chain connections through a bastion |
| Security | Host key validation, Secure Enclave P256 keys, credential keychain |
| Speed | Native-first hybrid engine, ~1s connects, pipelined SFTP transfers |
| Reliability | Auto-reconnect, wake/network healing, auth retry with clear errors |
| Extras | Zmodem transfer, SSH config import, Tabby importer |

### ⌨️ Inline Suggestions

- Warp-style ghost text with an instant local tier and an AI channel, ranked and learned from your usage
- Native candidate popup, accepted with a single keypress

### 🤖 AI Assistant

- Chat with **GitHub Copilot, Claude, OpenAI, Gemini, OpenRouter, OpenCode Zen, Ollama**, or any OpenAI-compatible endpoint
- **Agent mode** — supervised multi-step plans with a permission model and loop guards, reasoning streams, and rendered command output
- Generate and explain commands, diagnose error output, and target saved hosts on demand over SSH
- Custom provider configurations; your key, your data — no cloud relay

### ⚡ Productivity

- **Custom toolbar** — drag to reorder, right-click to customize, layout auto-saved
- **Snippets & command history** — stop retyping the same commands
- **Workspaces** — save and restore multi-session layouts
- **Broadcast** — type once into every pane
- **Quake terminal** — drop-down terminal on a global hotkey (⌘`)
- **Themes** — Dark, Light, Dracula, Nord, Solarized, plus your own
- **Session recording** — record panes to asciicast v2 and replay them later
- **Workspace templates & focus mode** — one-click layouts, distraction-free focus
- **Server monitor** — live per-tab resource stats, mirrored in the toolbar
- **Log profiles** — per-host highlighting with logfmt/JSON matching and a TrueColor picker
- **Easy import** — SSH config watcher auto-import, Tabby importer
- **iCloud sync & Sparkle auto-updates**

### 👥 Team Sharing

- Share hosts over LAN with Bonjour discovery and IP/PIN pairing
- Guest windows with floor control and presence

## 📸 Screenshots

_Coming soon._

## 🚀 Getting Started

1. Download the latest DMG from the [Releases page](https://github.com/iamJoyLiam/Bonk/releases) and drag **Bonk** into Applications.
2. Launch Bonk, add a host (name, address, port), and connect.
3. Optional: configure an AI provider in **Settings → AI** to unlock the assistant.

- Requires **macOS 15+** · Apple Silicon & Intel
- The app is signed; updates arrive automatically via Sparkle

## ⌨️ Shortcuts

| Action | Shortcut |
| --- | --- |
| Quake drop-down terminal | `⌘`` |
| Check for updates | `⌥⌘U` |
| Workspaces | `⌥⌘S` |

Most other shortcuts (new terminal, split panes, SFTP, AI, find…) are configurable in **Settings → Keyboard**.

## 🛠 Tech Stack

| Layer | Technology |
| --- | --- |
| UI | SwiftUI + AppKit (Swift 6) |
| Terminal rendering | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) |
| SSH | Hybrid engine — native-first with OpenSSH fallback |
| Storage | SwiftData |
| Updates | Sparkle |
| AI | OpenAI-compatible APIs, Copilot, Claude, Gemini, Ollama… |

## 🧑‍💻 Development

Requires Xcode 26. Supports macOS 15+.

```bash
git clone https://github.com/iamJoyLiam/Bonk.git
cd Bonk
open Bonk.xcodeproj
```

## 🏗 Architecture

The main window is an AppKit-owned `NSSplitViewController` shell hosting SwiftUI content — keeping the fully customizable `NSToolbar` stable and free from SwiftUI's window-toolbar ownership conflicts.

## 🤝 Contributing

Issues and pull requests are welcome. For feature ideas or bugs, open an issue first.

## 📄 License

[MIT](LICENSE)
