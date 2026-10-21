# 任务 ②：Anthropic 原生 tool_use

> 对应报告 `docs/agent-capability-gap.md` 的 **P0-2**。
> 状态：进行中
> 日期：2026-10-21

---

## 问题

```swift
// Bonk/Services/AI/Providers/ClaudeLLMProvider.swift:78（改动前）
throw AIError.unsupported("Claude tool loop is not enabled yet")
```

Claude 是**默认的 provider 类型**（`AIProviderType.swift:54`），默认模型 `claude-sonnet-5`。
而 Claude 是唯一一个**不能用 agent 工具循环**的主流 provider —— 旗舰 provider 缺席旗舰功能。

Anthropic 的工具协议也不是 OpenAI 协议换个名字：

| | OpenAI | Anthropic |
|---|---|---|
| 工具调用 | assistant 消息的 `tool_calls` | assistant 消息内容块里的 `tool_use` |
| 工具结果 | `role: "tool"` 消息 | **user 消息**里的 `tool_result` 块 |
| 工具参数 | JSON 字符串 | JSON **对象** |
| system prompt | 消息数组里的一条 | 顶层独立字段 |

所以这不是"把 OpenAI 的转换器换个名字"，是另一套规则。

---

## 范围

### 做

1. `AnthropicToolWire` —— 纯转换层，不碰网络
2. `ClaudeLLMProvider.toolCall` —— 走 Anthropic Messages API
3. `TokenUsage.anthropic(from:)` —— usage 解析
4. Claude 的 provider 默认能力 —— `supportsToolCalls: true`
5. `ClaudeLLMProvider` 的 `URLSession` 可注入（默认 `.shared`），让真实请求路径可测

### 不做（另批）

- **②-B：Claude 的 chat 路径仍是单轮**。`systemUserPair` 只取最后一条 user 消息，
  所以 Ask 模式下终端上下文（untrusted 块）**根本没到 Claude**。这是既有问题，不是本次引入。
- **③：合并两处 provider 解析**（`resolveProvider()` vs `resolveAgentProvider()`）

---

## 关键设计决定

| 决定 | 理由 |
|---|---|
| **手写 payload，不用 SwiftAnthropic** | SDK 的 `tool_use` input 类型是 `[String: DynamicContent]` 的**强类型枚举**，工具参数是任意 JSON，映射过去必然有损。普通 chat / streaming 路径仍然用 SDK |
| **tool_result 放进 user 消息** | Anthropic 的规则：工具结果是"工具告诉用户的事"，不是 assistant 说的话。而且必须紧跟在发起调用的 assistant 轮次之后 |
| **连续 tool_result 合并进一条 user 消息** | API 文档给的形式就是这样。分开成多条 user 消息会被服务端合并，不如自己合并 |
| **`stop_reason == "max_tokens"` → 丢弃工具调用** | 响应被 token 上限截断时，tool_use 的 `input` 根本没写完。执行它等于跑一条参数缺失的命令。Pi 用的是同一条规则 |
| **thinking 块既不是文本也不是工具调用** | 它是推理内容。混进 assistant 文本会让模型的话看起来像是想了又想 |
| **Claude 的能力由 provider 默认值决定** | 动态探测只读 OpenAI 风格的 model metadata，**对 Claude 从不运行**（`AIProviderCapabilityProbe.swift:166`），所以既有的探测缓存不会带着"不支持工具"的旧结论卡住 24 小时 |

---

## 验收结果

### 测试执行证据

| 项 | 值 |
|---|---|
| 指定套件 | `BonkTests/AnthropicToolWireTests` |
| requested | 13 |
| executed | 13 |
| failed | 0 |
| skipped | 0 |

### 对抗性变异

| 变异 | 期望 | 实际 |
|---|---|---|
| **C**：tool_result 改成 assistant 消息 | 指定门必须失败 | ✅ `toolResultIsAUserMessage()`、`consecutiveToolResultsMerge()` 失败，其余 11 项仍通过 |
| **D**：去掉 `max_tokens` 丢弃逻辑 | 指定门必须失败 | ✅ `truncatedReplyDropsToolCalls()` 失败，其余 12 项通过 |
| **E**：Claude 能力改回 `supportsToolCalls: false` | 指定门必须失败 | ✅ `claudeAdvertisesToolCalls()` 失败，其余 12 项通过 |

三次变异后均从**保存的原始副本**恢复（md5 逐个核对），未使用 `git checkout --`。

### 变异抓到的测试缺陷（真 bug）

第一次跑变异 C 时，指定门不是**失败**而是**把测试进程打崩**：

```
EXC_BREAKPOINT / SIGTRAP
libswiftCore.dylib Array._checkSubscript
  BonkTests AnthropicToolWireTests.toolResultIsAUserMessage() line 79
```

原因在测试自己：`wire[2]` 是**没有边界检查的下标**。实现被改坏时数组只有 2 个元素，
Swift 的数组越界检查直接 trap，进程死掉，Swift Testing 把**没跑到的用例**也报成 failed——
失败集合每次都不一样，还包含根本不可能受影响的 `claudeAdvertisesToolCalls()`。

这比"门失败了"更糟：门是**崩溃**的，信号是**假的**。

修法：所有下标访问改成边界安全（`Self.message(wire, at:)` + `first`）。
改完之后变异 C 的信号变得干净且可复现：13 项里恰好 2 项失败，就是那两条规则的门。

### 与基线的对比

| 运行 | 通过 | 失败 |
|---|---|---|
| baseline（原始代码） | 796 | 17 |
| 任务 ① 之后 | 818 | 16 |
| **任务 ② 之后** | **831** | 16 |

+13 = 本次新增的 13 项测试，全部通过。

失败集合与**原始 baseline 无任何差异**（`comm` 比对为空）。
与 baseline 第二次运行相比只多一个 `BudgetRuntimeTests/haltTrace()` ——
它在 baseline 第一次运行里也是失败的，第二次通过，属于既有的 flaky。

测试隔离复查：全量运行期间用 Quartz 采样，**12 次采样，0 次出现测试宿主在屏窗口**。
