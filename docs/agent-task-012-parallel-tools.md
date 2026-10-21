# 任务 ⑫：并行工具执行

> 对应报告 `docs/agent-capability-gap.md` 的 **P1-3**（前半：并行工具执行）。
> 日期：2026-10-21
> 状态：完成（并行工具执行已做；子 agent 未做）

---

## 问题

模型一轮里可以要好几件事。Bonk 一件一件做：

```swift
// Bonk/Services/Agent/Runtime/AgentRuntime.swift
for toolCall in response.toolCalls {
    switch await runToolCall(toolCall, ...) { ... }
}
```

三个独立的检查（`df -h`、`free -m`、`uptime`）就是三个往返。用户等的是三倍。

参考实现的做法（Claude Code `services/tools/toolOrchestration.ts`）：

- `partitionToolCalls()` 把**连续的并发安全工具**分一批；
- **非并发安全的工具单独成批**；
- `isConcurrencySafe` 抛异常时**保守当作不安全**（`:103-105`）。

Pi 同理（`agent-loop.ts:516-521`）：预检顺序执行，**执行**并发。

---

## 关键设计决定

### 一、能同批的只有"只读、且不会问用户"的调用

分批的判据不是"快不快"，是"**同时发生会不会互相干扰**"。一个调用能进同一批，
必须同时满足：

1. **不改任何东西**（读文件、只读的检查命令）；
2. **不会问用户**——所以屏幕上永远只有**一个**确认框。

第 2 条是第 1 条的推论，但值得单独说：Claude Code 的并发批次里全是只读工具，
所以它的并发**不会**带来两个对话框。Bonk 直接把它写成不变量：**能同批的调用
不会问用户**。

`ToolCallPlanner.isConcurrencySafe`：

- `read_file` / `list_dir` / `inspect_system` / `search_history` / `skill` → 安全
  （策略在任何 access mode 下都直接放行 ✓）；
- `run_command` → 命令被 `CommandSafety` 判为 **L0/L1** 才安全（L1 在任何
  access mode 下都不会弹框 ✓）；
- `todo_write`、**没被分类过的工具**、**参数解析不了的调用** → 不安全
  （保守 ✓，和参考实现一个路子）。

### 二、并行阶段**不碰**共享的消息数组

两个任务同时往一个数组里 append 是数据竞争。而且**模型看到的顺序不能取决于
哪个命令先跑完**。

所以：

- 每个并行调用有**自己的**消息数组；
- 批次跑完后，按**模型问的顺序**依次 append。

### 三、执行管理器从"一个槽"变成"一组"

这是并行化逼出来的一处必须改的地方。

```swift
// 改之前：一个槽
private(set) var activeHandle: (any CommandExecutionHandle)?
```

命令串行跑的时候，一个槽够用：第二个命令注册时，第一个早就结束了。
**并行时不够**——第二个命令注册会把第一个的 handle 覆盖掉，于是"停止"只会
打断最后注册的那个，**另一个还在跑**。

现在管理器存的是一组，`cancelActive()` 把**每一个**都按
中断 → 宽限 → 终止 → 宽限 → 关闭的流程升级一遍。用户说"停"，指的是**都停**。

### 四、界面上，一条命令的输出要落在**它自己**那条消息上

改之前，界面靠"最后一条 `commandOutput` 消息"认领输出：

```swift
case let .toolOutput(_, output):
    if let lastIndex = agentMessages.indices.last, agentMessages[lastIndex].role == .commandOutput {
```

并行时这是错的：先启动的命令**不是**最后启动的 ✗ —— 输出会落到别人的行上。

现在按**调用 id** 认领：开始时记下 id → 消息的对应关系，输出和完成都按 id 找回去。

---

## 过程中修掉的一个既有缺陷：问晚了，答案就丢了

写并行测试时发现 runtime 里的一处竞态（**与并行无关，是既有的**）：

```swift
emit(.permissionRequested(id: callId, ...))          // 问题先出去
let approved = await withCheckedContinuation { cont in
    pendingApprovals.withLock { $0[callId] = cont }   // 答案通道后开
}
```

**问题先广播，答案通道后开**：在这中间到达的答案，runtime 根本听不见——
`resolvePermission` 找不到 continuation，批准被**丢掉**，而 runtime 会**永远**
等一个早就来过又走了的答案。

`AGENTS.md` 里那条"驱动 runtime 的测试必须回应 `permissionRequested`，否则它会
挂住而不是失败"说的就是这个。

改法：**答案通道先开，问题后问**。问题一可见，答案就一定收得到。

> 这个缺陷在生产里几乎撞不上（人要看着弹窗点，通道早开了），但它是真的：
> 一次丢掉的批准 = agent 永远卡住。

---

## 改了什么

| 文件 | 改动 |
|---|---|
| `Bonk/Services/Agent/Runtime/ToolCallPlanner.swift` | 新增：分批计划（纯函数） |
| `Bonk/Services/Agent/Runtime/AgentRuntime.swift` | 循环按批次跑；新增并行批次路径；权限通道先开后问 |
| `Bonk/Services/Agent/AgentExecutionManager.swift` | 一个槽 → 一组；取消时全部升级 |
| `Bonk/Services/Agent/AgentToolExecutor.swift` | 工具事件按调用 id 认领，不再靠"最后一条" |
| `Bonk/Services/Agent/Runtime/AgentToolRegistry.swift` | 各工具有了 `toolName` 常量（名字只有一个出处） |
| `BonkTests/AgentParallelToolTests.swift` | 新增：14 个测试 |
| `BonkTests/AgentRuntimeContractTests.swift` | 新增：答案不丢的回归测试 |

---

## 验证

### 测试数

```
requested == executed == 15
failed == 0
skipped == 0
```

### 行为门禁

| 门禁 | 断言的是 |
|---|---|
| `twoReadsRunAtTheSameTime` | 两条读**真的同时在飞**——用一道栅栏：每条命令等另一条到达，串行时第一条会独自等到超时并**如实报告**（"alone"） |
| `theResultsKeepTheModelsOrder` | 结果按**模型问的顺序**回去：第一条故意慢 300ms，跑完顺序和模型顺序相反，消息顺序仍要是模型的顺序 |
| `twoApprovalsAreNotAskedAtOnce` | 两个要批准的命令，**一次只问一个**（事件顺序：请求→答复→请求→答复） |
| `cancellingStopsEveryCommand` | 取消时**每一个**在跑的命令都被中断（不是只有最后注册的那个） |
| `theOutputLandsOnItsOwnMessage` | 输出的落点由**调用 id** 决定 |
| `aBigBatchIsSplit` | 超过上限的批次被切分，且**顺序不变** |
| `testAnswerGivenAtOnceIsNotLost` | 问完立刻答，答案**不丢**，run 会结束（有界等待，不会挂死） |
| `theAnswerChannelOpensFirst` | 答案通道**先开**、问题**后问**（为什么这条是读源码的，见下） |

### 对抗性变异

| 变异 | 拿掉的东西 | 必须失败的测试 | 结果 |
|---|---|---|---|
| M1 | 分批判据（什么都算安全） | `aMutatingCommandRunsAlone` | ✓ |
| M2 | 结果按模型顺序回去 | `theResultsKeepTheModelsOrder` | ✓ |
| M3 | 并行（改回一个一个跑） | `twoReadsRunAtTheSameTime` | ✓ |
| M4 | 执行管理器的一组 handle | `cancellingStopsEveryCommand` | ✓ |
| M5 | 答案通道先开 | `theAnswerChannelOpensFirst`（+ 两个行为门禁） | ✓ |
| M6 | 界面按 id 认领输出 | `theOutputLandsOnItsOwnMessage` | ✓ |

> **M5 为什么还有一条"读源码"的门禁**：这个竞态的窗口只有几条指令宽
> ——"问题上线"到"答案能收"之间。**黑盒测试抓不住它**：任何从外面发出去的
> 答案都落在窗口之后。真正能证明的是**形状**——通道先开、问题后问。
> 行为门禁（`testAnswerGivenAtOnceIsNotLost`）在同一次变异里也失败了 ✓，
> 但它靠的是时机，所以形状门禁留作确定性的一条。

---

## 过程中的一个环境问题

验证时反复出现"**测试运行器在建立连接前就卡住**"（`The test runner hung before
establishing connection`）。取样显示宿主卡在 **dyld 打开 dylib** 的那一步——
**还没进到 app 代码**。

原因不在这里：当时机器上另有两个会话在跑重量级测试套件，load average 到了
**13–25**。这是环境问题，不是代码问题（同一份代码在机器闲下来时跑得干净）。

> 教训：看到"挂住"先分清是**门禁挂住**还是**环境挂住**——前者是缺陷，后者是
> 噪声。取样（`sample`）是分清两者的最快办法。

---

## 还没做的

- **流式执行器**：参考实现在模型**还在流式输出**时就开跑工具
  （`StreamingToolExecutor.ts:40`）。Bonk 现在是等这一轮的工具调用收齐了才跑。
- **子 agent**：需要 P0-1 的历史支撑。
