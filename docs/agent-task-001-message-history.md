# 任务 ①-A：会话级模型消息历史（Agent 跨轮次记忆）

> 对应报告 `docs/2026.10.21-agent-capability-gap.md` 的 **P0-1**。
> 状态：进行中
> 日期：2026-10-21

---

## 问题

`AgentRuntime.executeLoop` 每一轮都从 `[.system, .user]` 重建消息数组：

```swift
// Bonk/Services/Agent/Runtime/AgentRuntime.swift:156
var messages: [LLMMessage] = [
    .system(systemPrompt),
    .user(input),
]
```

模型看不到自己之前说过的话、跑过的命令、给出的结论。第二轮与第一轮在模型看来没有区别。

持久化的 SwiftData 会话**不能**直接回灌：`AgentEngine.appendAgentMessage`（`AgentEngine.swift:396-400`）
把 `commandOutput` 映射成 `.system` 角色，且记录里没有 `tool_call_id`，
所以它是一份**显示用**转录，不是一份合法的 tool-calling history。

---

## 范围

### 做

1. `AgentMessageHistory` 协议 —— 模型可见的历史，与 UI 转录分离
2. `ConversationMessageHistory` —— 按会话 ID 存；切换会话不串味，切回还能想起来
3. `AgentHistoryProjection.validPrefix(_:)` —— 纯函数，把历史裁成 provider 能接受的序列
4. `AgentHistoryProjection.boundedPrefix(_:maxCharacters:)` —— 纯函数，按字符预算保留最近的一段
5. `AgentRuntime` 注入 history：起始播种、逐条记录、压缩后同步
6. 生产路径装配（`AgentToolExecutor.runAgentToolLoop`）
7. `createNewConversation()` 在 agent 模式下同时清空模型记忆

### 不做（另批）

- SwiftData 落盘 / 跨重启恢复（报告 P1-4）
- 持久化 UI 转录与模型历史的合并（需要 schema 变更，另批）
- MCP / Skills / 并行工具 / 子 agent

---

## 关键设计决定

| 决定 | 理由 |
|---|---|
| **system prompt 不入库** | 每轮重建（含环境上下文、项目指令）。存旧副本会把昨天的 host 名钉进今天的 prompt |
| **最终回答入库，合成指令不入库** | 循环结束时 `AgentRuntime.swift:234` 直接 return，最终回答从未进 `messages`，但它是结论，必须让下一轮知道。合成指令（`:273`）是内部提示，不是用户发言 |
| **按会话 ID 分桶，不做单一列表** | 侧边栏切走再切回，对话记忆不该丢；两个会话也绝不能看到对方的轮次 |
| **无会话 ID 时历史为空** | 与其继承不相关运行的历史，不如没有记忆。宁可少记，不可串味 |
| **历史有字符预算** | 不加界的历史会让 prompt 随轮次线性膨胀，最后撞上预算控制器直接停机。保留最近的一段 + 重新投影 |
| **投影裁剪而不是直接发送** | provider 对"有 tool_calls 但没有对应 tool 结果"的 assistant 消息返回 400。运行被预算/取消打断时必然留下这种尾巴 |

---

## 验收标准

按 `AGENTS.md` 的 Security Regression Methodology，四件套：

1. **行为测试** —— 第二轮的模型请求里含有第一轮的用户消息、assistant 工具调用、tool 结果
2. **纯函数测试** —— `validPrefix` / `boundedPrefix` 的 allow / deny 两路独立可测
3. **wiring guard** —— 生产路径（`AgentToolExecutor.runAgentToolLoop`）真的绑定并注入了 history
4. **对抗性变异** —— 去掉注入 / 去掉记录 → 指定测试必须失败

外加 `AGENTS.md` 的 Test Execution Evidence：
`requested == executed`，`failed == 0`，`skipped == 0`。

---

## 验收结果

### 测试执行证据

| 项 | 值 |
|---|---|
| 指定套件 | `BonkTests/AgentMessageHistoryTests` |
| requested | 18 |
| executed | 18 |
| failed | 0 |
| skipped | 0 |

`requested == executed`，`failed == 0`，`skipped == 0`。

### 对抗性变异

| 变异 | 期望 | 实际 |
|---|---|---|
| **A**：去掉 runtime 的记录调用（`appendToHistory` 与 assistant/user turn） | 指定行为测试必须失败 | ✅ `secondTurnCarriesTheFirstTurn()` 失败，`returningToAConversationRestoresItsMemory()` 失败 |
| **B**：去掉生产路径的注入（`AgentToolExecutor` 不传 `messageHistory:`） | wiring guard 必须失败 | ✅ `productionPathWiresTheHistory()` 失败 |

两次变异后均从**保存的原始副本**恢复（未使用 `git checkout --`），并重跑基线。

### 变异过程中抓到的一个真实 bug

第一次实现里，`record()` 每次写入都跑一遍投影。结果是：**assistant 发出工具调用、工具结果还没到达**这个中间态
被投影判定为"调用未被应答"，于是这一轮被当场丢弃；随后到达的工具结果就成了孤儿，也被丢弃。

表现：第二轮的模型请求里只剩 `[system, user, "up 3 days"]`，工具调用和工具结果整轮消失。

纯函数测试全绿——因为它们测的是**完整**序列。问题出在"投影"和"增量写入"的交互上，
只有把断言放在**模型实际收到的请求**这一层才会暴露。

修复：写入只做**预算裁剪**，投影只在**读取**时做。并补了回归测试
`halfWrittenTurnSurvivesTheWrite()`。

### 与基线的对比

| 运行 | 通过 | 失败 |
|---|---|---|
| baseline 第 1 次 | 796 | 17 |
| baseline 第 2 次 | 796 | 16 |
| **本次改动** | **818** | 16 |

22 项新测试（18 + 4）全部通过。两次 baseline 与改动后的失败集合，差异**只在
`AgentCommandDeadlineTests` 这一条**：该套件在 baseline 就会随机挂不同的用例
（第 1 次 `cancellationBeatsDeadline` 挂了 **600 秒**，第 2 次 `quickCommandUnaffected`
挂，改动后 `longHealthyCommandSurvives` 在 0.000 秒挂——即 setup 阶段就没起来）。
属于既有的时序/端口 flaky，与本次改动无关。

### 测试隔离的验证方式

不是靠"看代码觉得不会弹窗"，而是用 Quartz 直接读**真正在屏幕上的窗口**
（`CGWindowListCopyWindowInfo` + `kCGWindowListOptionOnScreenOnly`），并按
owner PID 过滤出测试宿主：

```
=== RESULT ===
samples with a clean test host: 160 ; worst on-screen window count: 0
```

全量测试运行期间连续采样 160 次，测试宿主**每一次的在屏窗口数都是 0**。

对照：AX 层会列出测试自己创建的 `NSWindow` 对象（`InputCriticalPathContractTests`
等），但那些窗口没有 order front，Quartz 查不到——即它们不在屏幕上。


---

## 附带修复：测试运行不再劫持开发者的机器

全量测试跑起来时，测试宿主就是 Bonk.app 本身，于是每次跑测试都会：

1. 打开主窗口（1200×800）
2. 弹出 Quake 终端面板（`.floating` 层级，盖在一切之上）
3. 注册系统级全局热键、申请辅助功能权限
4. 抢走前台焦点
5. **在启动和退出时执行 `pkill -9 -f 'bonk-ssh-.*\.sock'`** —— 杀掉开发��正在使用的 Bonk 的
   活跃 SSH 会话
6. 写生产环境的 `host_key_records.json`（host key 信任文件）

第 5 条是真正破坏工作的：模式按 socket 路径匹配，不区分归属。

修复（`TestEnvironment.isRunningTests`，`#if DEBUG`，Release 构建恒为 false）：

| 文件 | 改动 |
|---|---|
| `Bonk/Core/TestEnvironment.swift` | 新增：宿主进程检测 |
| `Bonk/State/BonkAppDelegate.swift` | 测试宿主不创建主窗口 |
| `Bonk/ContentView.swift` | 测试宿主不 setup Quake 面板 |
| `Bonk/Services/SSH/OpenSSHBackend+ControlMaster.swift` | 测试宿主不执行 mux 清理 |
| `Bonk/Services/SSH/HostKeyTrustMigration.swift` | 测试宿主不写生产 host key 信任文件 |

验证方式：在全量测试**运行中**抓取桌面快照 —— 焦点窗口、应用列表与运行前完全一致，
无 Quake 面板，无额外 Bonk 窗口。

守护测试：`BonkTests/TestEnvironmentIsolationTests.swift`（4 项）。

---

## 本次踩到的两个坑（写给下一个人）

### 1. 不要用 `test-without-building` 跑这个套件

`xcodebuild test-without-building` 在本仓库会让
`TeamSSHHostKeyPinningTests/secondConnectionToTheSameHostSucceeds()` **稳定失败**（4/4），
而 `xcodebuild test` 正常。

已验证这与本次改动无关：**baseline 代码 + `test-without-building` 同样 4/4 失败**。
两条路径的差别是 app bundle 的重建/重签名，`test-without-building` 复用旧 bundle，
TeamRelay 的 host key 学到的东西因此不同。

结论：全量对比必须用 `test`，不能用 `test-without-building`。用后者得到的失败集合是假的。

### 2. `TeamSSHHostKeyPinningTests` 本身就是 flaky

用正确的 `test` 跑，改动前后都是 **1/9 左右**失败（baseline 1/6，我的版本 1/9）。
是既有缺陷，不是本次引入。

它的断言写法也有问题（`??` 的优先级高于 `!=`）：
`learned != identityStore.pinnedTeamIdentityFingerprint() ?? learned`
在 identity 指纹尚未 pin 时读作 `learned != learned`，恒假。
但既然失败的真实成因是 runner 模式而非这条断言，就**没有去动它** ——
不相干的改动只会让 diff 变脏。留在这里记录。


