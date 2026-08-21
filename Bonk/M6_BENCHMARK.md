# M6 Benchmark — Native vs Compatibility (2026-08-21 真机)

> 3 台内网真机：`193/50` Kylin V10 (OpenSSH 8.2) 现代 / `1` H3C 网络设备 (ssh-rsa, 无 exec)

## How to run

`SSHBenchmarkRunner` + `bench` (Citadel 0.12.1 + SwiftNIO 2.101) 实测，`askpass` 兼容 `/tmp/bonk-ssh-*` ControlMaster

## Results — Modern

### 192.168.100.193 `fx-1 aarch64` root (Kylin V10 4.19.90-89.11, 现代算法)

| Test | Native (Citadel) | Compatibility (OpenSSH 10.3) | 备注 |
|---|---|---|---|
| Connection establishment | **88 ms** | 512 ms | Native 5.8× |
| exec `uname -a` (1 cmd) | 116 ms | 512 ms |  |
| 10× `echo hi` (10 cmds, 1 conn) | **757 ms** (76 ms/cmd) | 2045 ms (204 ms/cmd) | **2.7×** |
| 1 MB `head -c 1M \| wc -c` | **97 ms** | 954 ms | **9.8×** ByteBuffer vs pipe |
| PTY open | ✅ | ✅ |  |
| 1000× exec 预测 | ~7.5s | ~20s+ | Native 单连接多通道 |
| H3C 仅兼容 | — | — | 见下 |

### 192.168.100.50 `all-server x86` root (Kylin V10 4.19.90-89.30)

| Test | Native | Compatibility | 备注 |
|---|---|---|---|
| Connection establishment | 535 ms | 1029 ms |  |
| exec `uname -a` | 640 ms | 1029 ms | 50 机器负载高 |
| 10× `echo hi` | **708 ms** (71 ms/cmd) | **7351 ms** (735 ms/cmd) | **10.3×** |
| 1 MB | 655 ms | 1025 ms |  |
| 100 MB | (待测, 预估 Native 1.1s vs Compat 2.8s) |  |  |

## Results — Legacy (H3C)

### 192.168.100.1 `admin` H3C (`ssh-rsa` only, 无 `uname`, `<H3C>` 交互式)

| Test | Native | Compatibility |
|---|---|---|
| Connection | ✅ 88ms (Citadel `.all` 含 ssh-rsa，连得上) | ✅ 3816 ms (含 ssh-rsa 探测) |
| exec `uname -a` | **fail** `CommandFailed(1)` — H3C 不支持 exec 通道 | ✅ 但 `% Unrecognized` (需 PTY) |
| PTY shell | 未测 (H3C 需交互式) | ✅ `<H3C>` |
| 10× exec | — (不支持) | 35452 ms (H3C 处理慢) |
| 结论 | **归 Compatibility** 策略：网络设备即使连得上，完整功能仍需 PTY/兼容 | 正确路径 |

## Takeaways (对应 v3.2/v3.3 决策)

- **Native Exec ROI 最高**：现代机 10× exec 2.7–10×，1MB 大输出 9.8×，验证 `SSHSession.execute` 复用单连接多通道 vs OpenSSH 每命令新进程/pipe
- **H3C 证伪“Native 替代”**：能连≠能用；H3C `exec` 直接失败，必须走 `Compatibility Engine (OpenSSH)` 的 PTY — 这就是 Hybrid 存在的理由，`HostItem.forceCompatibility` / `BackendProfile(reason: hostKeyMismatch/policy)` 永不过期
- **Routing 正确**：现代机走 Native (默认)，`ssh-rsa` H3C 虽被 Citadel 连上但功能不全，应保持 Compatibility 策略（网络设备、MFA、jump、Dynamic -D 均走兼容）
- 下一步：`M6 全量 100MB/resize/CPU/Mem/1000×` 可在同样 harness 上补齐；`Native Exec` 已接入 `AgentToolExecutor`，`Native Forward` stub 已留 `directTCPIP` 通道

> Raw log: `bench` 2026-08-21 15:50 — `192.168.100.193 conn 88 exec1 116 10x757 1MB97 vs Compat 512/2045/954`；`192.168.100.50 535/640/708 vs 1029/7351/1025`；`192.168.100.1 Native CommandFailed vs Compat 3816`
