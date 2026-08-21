# M6 Benchmark — Native vs Compatibility

> 来源 `docs/ssh-vnext-architecture.md §15` 9项表。填表前先跑 `SSHBenchmarkRunner` 真机。

## How to run

```swift
let runner = SSHBenchmarkRunner()
let result = await runner.runAll(factory: { backend in
    // 1. Modern host where both engines work (for fair comparison):
    //    - .native: let req = SSHConnectionRequirements(..., endpoint: endpoint)
    //      return try await coordinator.connectForBenchmark(req, force: .native)
    //    - .compatibility: same but force Compatibility (forcedCompatibility / direct)
    // 2. Legacy host: only .compatibility will succeed.
    try await makeSession(backend)
}, host: "192.168.1.10", port: 22)
print(result.markdownTable)
```

`factory` 需由调用方注入（Coordinator 暂未暴露 `force`，可临时代 `HostItem.forceCompatibility` 或直接 `NativeSSHSession/CompatibilitySSHSession`）。

## Results

### Modern server (Ubuntu 24.04, direct, password) — both engines succeed

| Test | Native | Compatibility |
|---|---|---|
| Connection establishment |  |  |
| Interactive latency (keypress→echo) |  |  |
| 1 MB output (`cat`) |  |  |
| 100 MB output (`cat`) |  |  |
| PTY resize |  |  |
| Long-running (10 min idle) |  |  |
| CPU (avg) |  |  |
| Memory (peak) |  |  |
| 1000× exec (`echo hi`) |  |  |
| SFTP throughput |  |  |

### Legacy bastion (H3C / old OpenSSH, dh-group1, ssh-rsa) — only Compatibility

| Test | Native | Compatibility |
|---|---|---|
| Connection establishment | fail (kexMismatch) |  |
| 1000× exec | — |  |

## Notes

- 高延迟链路与大输出重点看 `ByteBuffer` 流 vs `PTY pipe` 背压差异。
- Exec 1000 次差距预期最大：Native `1000 channel request` vs Compat `1000 Process spawn`。
- CPU/Mem 用 Instruments `os_signpost` 或 `SSHBenchmark.swift` 的 `extra` 字段记录。
