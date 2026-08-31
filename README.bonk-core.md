# Bonk Universal Architecture (Rust Core + Tauri)

AI团队友好版：Mac保持原生，Windows/Linux吃同一个Rust核。

## 目录结构

```
Bonk/                          # 现有Mac原生App (不动)
bonk-core/                     # Rust共享核 - 唯一真理
  src/
    models/   # 纯DTO (HostItemDto, SshConnectionConfig) - 无SwiftData
    ssh/      # SshSession/PtyChannel/SftpChannel trait + russh实现
    sftp/     # SFTP helpers
    pty/      # portable-pty 封装 (ConPTY on Win, forkpty on Unix)
    storage/  # HostStore trait + SQLite/InMemory 实现 (替换SwiftData)
    keychain/ # CredentialStore trait + keyring/InMemory 实现
    ai/       # AiProvider trait (OpenAI/Claude/Ollama)
    ffi/      # C ABI 给Swift FFI用
  examples/connect.rs
bonk-mac-ffi/                  # Swift Package - 桥接Rust核给Mac
  Sources/BonkCoreFFI/
    BonkCore.swift
    BonkCore+SSH.swift
bonk-win/                      # Windows (Tauri v2 + xterm.js)
  src/        # React + xterm.js + Zustand
  src-tauri/  # Rust (直接依赖 bonk-core, 零IPC开销)
```

## 5分钟跑起来

### 1. 验证Rust核 (无需Tauri)

```bash
cd bonk-core
cargo check          # 检查编译
cargo test           # 跑FFI单测
cargo run --example connect  # mock连接演示
```

### 2. 跑Windows前端 (Vite mock, 无需Rust)

```bash
cd bonk-win
npm install
npm run dev          # http://localhost:1420 - 本地mock终端可打字
```

### 3. 跑完整Tauri (Rust核 + 前端)

```bash
cd bonk-win
cargo install tauri-cli --locked  # 首次
npm run tauri:dev    # 打开原生窗口, Rust `ssh_connect` 真实走bonk-core
```

### 4. Mac侧接入Rust核 (渐进式)

```bash
cd bonk-core && cargo build --release  # 生成 libbonk_core.a
# 然后在 Bonk.xcodeproj 中把 bonk-mac-ffi 作为 local package 引入
# Feature flag: UserDefaults "useRustCore" 控制走 Citadel 还是 Rust
```

## 设计要点

- **Trait抽象**: 上层只依赖 `SshSession/PtyChannel/SftpChannel/HostStore/CredentialStore`，不知底层是Citadel还是russh
- **DTO先行**: `HostItemDto` 用 `serde` JSON过FFI，比C struct稳定10倍
- **Mock优先**: `RusshSession` 现在是mock，所以 `cargo check` 和 `vite dev` 都能跑，不阻塞并行开发
- **平台分发**: `portable-pty` 自动处理 Win ConPTY / Unix pty，`keyring` 自动处理各OS钥匙串

## AI团队分工建议

- **模型/推理**: 只改 `bonk-core/src/ai/`，加新provider实现 `AiProvider` trait即可
- **SSH/SFTP**: 改 `bonk-core/src/ssh/`，前端无感
- **UI/交互**: 只改 `bonk-win/src/components/`，Rust核不动
- **提示词/工具**: `bonk-core/src/ai` + `bonk-win/src/lib/tauri.ts` 打通

## 下一步TODO (按优先级)

- [ ] `bonk-core/src/ssh/session.rs` 接真实 `russh` (替换mock)
- [ ] `bonk-win/src-tauri/src/main.rs` 保存 `PtyChannel` 句柄以实现 `ssh_write/resize` 真实转发
- [ ] `storage/sqlite` 打开 `storage-sqlite` feature，替换 `InMemoryHostStore`
- [ ] 前端 `Sidebar` 接 `invoke("list_hosts")` 而非MOCK_HOSTS
- [ ] 打包: `npm run tauri:build` 生成 `.msi` / `.exe`

## 常见问题

**Q: Mac现在要改吗？** 不用。`Bonk/` 原样发版，`bonk-core` 和 `bonk-win` 是新增目录，零耦合。

**Q: Rust不会怎么办？** AI团队只改 `ai/` 和前端，SSH部分可先用mock，等有Rust同学再替换。

**Q: Linux呢？** `bonk-win` 改名 `bonk-desktop`，`cargo build` 同一套，Tauri原生支持Linux。
