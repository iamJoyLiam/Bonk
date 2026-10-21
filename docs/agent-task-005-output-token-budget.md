# 任务 ⑤：统一的输出 token 预算

> 对应报告 `docs/agent-capability-gap.md` 的 **P0-4**。
> 日期：2026-10-21

---

## 问题

报告里原本记的是"agent 每轮被截断到 2000 输出 token"。实际查下来更糟：
**同一个模型、同一段对话，取决于走哪条代码路径，预算都不一样。**

| 路径 | 改动前的默认 |
|---|---|
| Claude · Ask 模式（chat） | **500** |
| Claude · agent 工具循环 | 4096 |
| OpenAI · chat | 4096 |
| OpenAI · agent 工具循环 | **2000** |
| OpenAI Responses · chat | **500** |
| OpenAI Responses · 工具循环 | **2000** |

**500 token 大约 350 个词**。也就是说：Claude 的每一次普通回答、OpenAI Responses
（OpenAI 的默认协议）的每一次普通回答，都会被从中间截断。

而且**干得最多的那条路径，预算最小**：agent 工具循环每一轮要装下工具调用、
围绕它的推理、还有模型的回答——它拿到的是 2000。

五个不同的默认值散落在 adapter 和 networking helper 里，各自写死：

```swift
// Bonk/Services/AI/AIProviderNetworking+SDK.swift:119（改动前）
maxTokens: maxTokens ?? provider.maxOutputTokens ?? 500,

// Bonk/Services/AI/Providers/OpenAICompatibleLLMProvider.swift:122（改动前）
let resolvedMaxTokens = maxTokens ?? config.maxOutputTokens ?? 2000
```

---

## 范围

### 做

1. 新增 `OutputTokenBudget` —— **唯一**的预算解析点
2. 全部 8 个解析点改走它
3. `OutputTokenBudget` 的规则：per-call > 保存的设置 > provider 默认 > 兜底
4. Claude 的 provider 默认给 8192（Claude 模型都吃得下，Claude Code 自己也用 8K 保守默认）
5. 兜底 4096
6. 抽出共享的 `StubHTTPURLProtocol`（按 host 分槽，避免并行测试互相踩）

### 不做

- 不做 per-model 的精细上限表。没有可靠的来源就不该凭记忆写死——写错的代价是
  API 400，而"给少了"只是少几个 token。
- **不夹紧用户的显式设置**。用户填的值就是用户的决定；模型收不收得下，provider 说了算，
  被拒绝的报错比静默夹紧更能说明问题。

---

## 关键设计决定

| 决定 | 理由 |
|---|---|
| **一个解析点，不是一个常量** | 把默认值统一还不够——分散的默认值会再次分散。要让"同一条路径只有一种算法"，需要一个所有路径都必经的函数 |
| **per-call 压过保存的设置** | per-call 是更具体的指令 |
| **非正值当作没设置** | UI 只存正数，但解析点不该假设调用方守规矩 |
| **不夹紧用户设置** | 夹紧会把用户"我设 16384"悄悄变成 8192，而且没有任何提示 |
| **Claude 8192 / 兜底 4096** | 都是各家模型都吃得下的值，请求超限从来不该是一次对话失败的原因 |

---

## 验收结果

### 测试执行证据

| 项 | 值 |
|---|---|
| 指定套件 | `BonkTests/OutputTokenBudgetTests` |
| requested | 8 |
| executed | 8 |
| failed | 0 |
| skipped | 0 |

### 行为测试选在哪一层

**同一个 provider 的 chat 路径和 tool 路径，必须解析出同一个预算** —— 这就是缺陷本身。

- chat 路径：直接读 `AIProviderNetworking.claudeMessageParameter(...).maxTokens`
  （SDK 即将发出去的那个参数）
- tool 路径：用 stub 拦下**真正发出去**的请求，读 body 里的 `max_tokens`

两边对比。这比断言"某个函数返回 4096"强得多：后者在两边各写各的情况下照样能过。

### 对抗性变异

| 变异 | 期望 | 实际 |
|---|---|---|
| **I**：OpenAI 工具循环恢复自己的 `?? 2000` | 指定门必须失败 | ✅ `openAIPathsAgree()` 失败，其余 8 项通过 |
| **J**：Claude chat 路径恢复 `?? 500` | 指定门必须失败 | ✅ `claudePathsAgree()` 失败，**并且**源码门 `noPathHasItsOwnDefault()` 也失败 |

J 这一条同时触发两个门，是对的：既证明了"两条路径必须一致"，也证明了"不许再有路径自己写默认值"。

另有源码门 `noPathHasItsOwnDefault()`：扫描 `Bonk/Services/AI/` 下所有文件，
任何 `maxTokens ... ?? 500|2000|4096` 的写法都会让它失败。

### 过程中修掉的两个测试缺陷

1. **stub 的全局状态**。`StubHTTPURLProtocol` 原来只有一个全局槽，Swift Testing 并行跑测试时
   互相覆盖——失败集合每次都不一样，还包含根本不可能受影响的用例。改成**按 host 分槽**。
2. **`reset()` 抹掉所有 host**。一个测试的 `reset()` 会把另一个测试正要断言的请求清掉。
   改成 `reset(for:)`。

这两个都不是产品缺陷，但都会让"测试通过"这句话变得不可信——和任务 ② 里那个
`wire[2]` 越界是同一类问题：**信号要是假的，验证就是假的**。

### 与基线的对比

| 运行 | 通过 | 失败 |
|---|---|---|
| baseline（原始代码） | 796 | 17 |
| 任务 ①②④ 之后 | 840 | 16 |
| **任务 ⑤ 之后** | **848** | 17 |

+8 = 本次新增的 8 项测试，全部通过。

失败集合与原始 baseline 的差异只有 `TeamSSHHostKeyPinningTests/secondConnectionToTheSameHostSucceeds()` ——
既有 flaky（实测 baseline 1/6 失败，本次改动 1/9，**失败率相同**），与本次改动无关。

测试隔离复查：全量运行期间用 Quartz 采样，**12 次采样，0 次出现测试宿主在屏窗口**。
