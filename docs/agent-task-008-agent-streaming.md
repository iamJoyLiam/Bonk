# 任务 ⑧：agent 循环流式

> 对应报告 `docs/agent-capability-gap.md` 的 **P1-7**（顺带关掉 **P2-3**）。
> 日期：2026-10-21
> 状态：完成

---

## 问题

`AgentModelGateway.stream` 存在，**没有生产调用者**。agent 循环用 `modelGateway.chat`
拿一整轮——用户在整轮结束前看不到模型的任何文字。

这不是"把一个已有的开关打开"。**流式的一轮不是流式的答案**：
模型一边写文字一边要命令跑，两半是**交错**到达的。只认文字的解析器会把工具调用丢掉，
而没有工具调用，整个 agent 循环就没了。

所以任务其实是：**让一条"带工具的流式轮次"真的存在**。

---

## 关键设计决定

### 不用改 `LLMProvider` 协议

能流式带工具调用的 provider 不是所有线协议都做得到，也不该去问做不到的 provider。
所以新开一个协议：

```swift
protocol LLMStreamingToolProvider: Sendable {
    func streamTurn(messages:tools:maxTokens:) -> AsyncThrowingStream<LLMStreamEvent, Error>
}
```

`AgentModelGateway.streamTurn` 返回**可选**：provider 不支持就返回 nil，
runtime 退回 `chat`。**行为完全一样，只是不流式**。回退是结构性的，不是靠判断。

### 解析器是纯的

线协议里麻烦的部分是：片段会乱序、会跨块、会混在一起。
把这些从传输里拆出来，它们就能直接喂恶意输入来测。

- `OpenAIStreamAccumulator` —— `choices[0].delta.tool_calls[]`，按 `index` 归组
- `AnthropicStreamAccumulator` —— `content_block_start` 开块，`input_json_delta` 是参数片段

**按模型的 `index` 排序，不按到达顺序**：一个调用的片段可能和另一个的交错到达，
按到达顺序跑就会把模型的第二条命令先跑了。（这是测试逼出来的——第一版按到达顺序，
`severalToolCallsKeepTheirOrder` 直接失败。）

### 文本一到就发，不攒着

累加器每吃进一个 payload 就**返回**这一段带来的事件，传输层立刻发出去。
攒到最后再发等于没做流式——用户还是整轮结束才看到。

### transcript 把碎片拼回去

transcript 记的是**说了什么**，不是**怎么传的**。所以连续的
`.assistantTextDelta` 在导出时拼回一行 `[Assistant]: ...`。

### 流式轮次不再额外发一次全文

发了碎片就等于发了全文。再发一次，transcript 里就有两份。

---

## 验收结果

### 测试执行证据

| 项 | 值 |
|---|---|
| 指定套件 | `AgentStreamingTurnTests` + `OpenAIStreamAccumulatorTests` + `AnthropicStreamAccumulatorTests` |
| requested | 17 + 1 |
| executed | 17 + 1 |
| failed | 0 |
| skipped | 0 |

### 第一次变异活下来了——这才是重点

**变异 T**：runtime 把碎片攒着，等这一轮结束再发。也就是"用户还是整轮结束才看到"。

**它没有让任何测试失败。**

原因是我原来的门只断言了**顺序**：碎片事件在工具事件之前。
而攒着发的时候，顺序**也是**对的——碎片仍然在工具跑之前发出去
（因为工具是在 `runModelTurn` 返回之后才跑的）。

**顺序不是"流式"的证据。** 攒着发和实时发，事件顺序可以完全一样。

### 门该怎么选

要让"这一段是在这一轮**还在跑的时候**送出去的"可观察，
就得**让这一轮卡住**：

> 网关发完第一段碎片就**阻塞**，直到测试放行。
> 于是"这一轮还没结束"变成一个事实，而不是一个推测。

新增的门 `theFirstPieceIsDeliveredWhileTheTurnRuns`：
网关卡住，测试轮询事件流——碎片到了吗？
攒着发的话，碎片永远不会出现（这一轮还没结束，没地方发），轮询超时 → 门失败。

**注意**：失败时测试必须放行门，否则挂死而不是失败。

### 对抗性变异

| 变异 | 期望 | 实际 |
|---|---|---|
| **T**：碎片攒到这一轮结束再发 | 指定门必须失败 | ✅ `theFirstPieceIsDeliveredWhileTheTurnRuns()` 失败（第一版门没抓到，见上） |
| **U**：流里的工具调用被丢掉 | 指定门必须失败 | ✅ `theModelSeesTheWholeAnswer()`、`theAnswerArrivesBeforeTheToolsRun()` 失败 |

---

## 与基线的对比

| 运行 | 通过 | 失败 |
|---|---|---|
| baseline（原始代码） | 796 | 17 |
| 任务 ①–⑦ 之后 | 884 | 15 |
| **任务 ⑧ 之后** | **899** | 18 |

失败集合相对原始 baseline 的差异：

- `AgentTraceEventTests/ring()` —— 断言的是 `DecisionTraceRecorder.shared` 这个
  **全局共享** ring 的条数；全量并行时别的测试往同一个 ring 里写，条数就不是 2 了。
  **单独跑两次都通过**。既有竞态，与本次改动无关（本次没有碰 trace recorder）。
- `TeamSSHHostKeyPinningTests/secondConnectionToTheSameHostSucceeds()` —— 既有 flaky
  （实测 baseline 1/6 失败，本次改动同量级）。
- `AgentCommandDeadlineTests/cancellationBeatsDeadline()` —— baseline 就在失败，这次通过。

+15 = 本次新增的 18 项测试 − 3 条新增的既有 flaky 失败。

测试隔离复查：全量运行期间用 Quartz 采样，**14 次采样，0 次出现测试宿主在屏窗口**。

---

## 顺带关掉的：P2-3（没有 reasoning 展示）

`AgentEvent.thinking` 存在，但**没有任何代码发出它**。
流式轮次里两种线协议都会送 reasoning（OpenAI 系的 `reasoning_content`、
Anthropic 的 `thinking_delta`），所以现在它有发射者了——
runtime 把 reasoning 片段作为 `.thinking` 发出去，UI 本来就接这个事件。
