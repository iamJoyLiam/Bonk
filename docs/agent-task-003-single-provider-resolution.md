# 任务 ③：一次运行，一个 provider 解析

> 日期：2026-10-21
> 状态：完成

---

## 问题

Agent 路径对"用哪个 provider"这件事**解析了三次，走的是两套机制**：

| 位置 | 解析方式 | 取到的是 |
|---|---|---|
| **决策**（走工具循环还是计划流） | `resolveProvider()` | 用户当前 active 的 provider |
| **工具循环**（真正执行） | `resolveAgentProvider(task: .agentExecute,)` | **路由器**挑的 provider |
| **计划流**（生成计划） | `resolveProvider()` | 用户当前 active 的 provider |

决策和执行因此是**对不同 provider 做的**。

### 实际后果：工具循环对一部分用户不可达

路由器有一条**硬过滤**：`requiresCapability: "toolCalls"` —— 不能工具调用的 provider 直接出局。
所以：

> active = Gemini（不能工具调用），同时配了 Claude（能）→ 
> 路由器把 Gemini 过滤掉，挑了 Claude；
> 但**决策**看的是 active 的 Gemini，说"不能工具调用" → 走计划流。

**结果：明明有能工具调用的 provider 摆在那里，工具循环永远轮不到。**

### 顺带发现的第四个问题

工具循环用 `LLMProviderFactory.provider(...)` **直接**造 provider，绕过了可注入的 resolver。
而 `LLMProviderFactory.swift` 自己的注释写着：

> Anything that re-introduces a direct `LLMProviderFactory.provider(...)` call inside
> `AgentEngine` is a regression the provider-boundary tests are meant to catch.

绕开 resolver 的后果是：agent 路径**没法用替换过的 provider 跑测试**。
本任务的行为测试就是因此才写得出来。

---

## 范围

### 做

1. **一次解析**：provider 实例造一次，决策和执行用同一个
2. **决策也走路由器**：这样"能不能工具调用"问的是**真正会去回答的那个 provider**
3. 工具循环改为接收 provider 实例，不再自己解析
4. `providerResolver` 从 `private` 放开（它跨文件，且它的全部意义就是可替换）
5. 计划流改成接收已解析的 provider（第三次解析消失）
6. `runAgentDirectSynthesis` 也改走 resolver
7. **删掉死代码**：`runToolIteration` / `executeToolCalls` / `executeAgentCommand` /
   `mirror` / `AgentToolContext` / `AgentTools.swift`

### 不做

- 不改路由策略本身（路由器挑谁，仍然是路由器的事）
- 不动 `AITerminalMirror`（见下面"顺带发现"）

---

## 关键设计决定

| 决定 | 理由 |
|---|---|
| **决策走路由器，而不是 active provider** | 决策问的必须是"真正会去回答的那个 provider 能不能工具调用"。问 active 的话，答案和实际执行者不是同一个 |
| **provider 实例造一次，两处共用** | 决策看能力和执行用能力，必须是同一份能力 |
| **工具循环不再解析** | 自己再解析一次，就又是两个 provider 了 |
| **删死代码** | 那条死路径带着**自己的一份安全流水线**和**自己的信任判断**。它永远不会被执行，所以永远不会被测试覆盖——但它看起来像一条正经路径 |
| **不放宽 resolver 的可见性之外的任何东西** | resolver 是 seam，本来就该可替换；不是新机制 |

---

## 验收结果

### 测试执行证据

| 项 | 值 |
|---|---|
| 指定套件 | `BonkTests/AgentProviderResolutionTests` |
| requested | 5 |
| executed | 5 |
| failed | 0 |
| skipped | 0 |

### 行为测试选在哪一层

直接驱动**真实的 `AgentEngine.runAgent`**，用一个会数数的 resolver 记录它被要求造了几个 provider。

关键设计：resolver 交出去的 provider，**能力取自真实工厂对同一份 config 的解析结果**
（`AIProviderCapabilityResolver.resolve`）。这样测试仍然能表达"这个 provider 不能工具调用"——
一个固定能力的 stub 表达不了缺陷所在的那个场景。

### 对抗性变异

| 变异 | 期望 | 实际 |
|---|---|---|
| **L**：决策改回看 active provider（**还原原缺陷**） | 指定门必须失败 | ✅ `toolLoopIsReachableDespiteAnIncapableActiveProvider()` 失败，其余 4 项通过 |
| **M**：工具循环自己造 provider（绕开 seam） | 指定门必须失败 | ✅ `noFileBypassesTheResolver()` + 两个行为测试失败 |

### 第一次变异没有失败——这才是有意思的地方

第一次写 L 变异时，它**没有**让任何测试失败。查下来是变异本身**不忠实**：

`resolveAgentProvider` 有一行副作用——

```swift
activeProvider = provider     // AgentEngine.swift:140
```

**路由器挑中的 provider 会把用户当前的 active provider 覆盖掉。**

所以"在解析之后再问 active provider"问到的**已经是路由器挑的那个了**，
不是用户原本选的那个。原代码是在解析**之前**问的。把变异改成忠实于原来的顺序
（在解析前先取一次 active），指定门才正确失败。

> **顺带发现**：路由结果会**静默改掉用户当前选中的 provider**。
> active 是 Gemini、配了 Claude 时，跑一次 agent 任务之后，设置里 active 就变成 Claude 了。
> 这不在本任务范围内（改它会影响路由行为），但记在这里。

### 过程中修掉的一个测试缺陷

第一版测试用 `.gemini` / `.claude` + `apiKey: "key"`。
但 `AIProviderConfig.init` **会把 apiKey 写进钥匙串**——测试留下的条目没人拥有。

改用 `.ollama`（不能工具调用）和 `.custom`（能工具调用）：两种类型都**不需要 API key**，
于是测试完全不碰钥匙串。已经写进去的两条孤儿条目（值为字面量 `"key"`，据此精确识别）
已删除。

---

## 顺带发现（未修）

### 1. `FoldRuntimeTests` 单独跑会**挂死**

`foldSkipsDialog` 和 `foldTrace` 不断言权限请求，只是等 `.completed`。
一旦折叠没生效，runtime 发出 `permissionRequested` 就**永远等下去**。

**已证明是既有问题，与本任务无关**：把本任务的改动 `git stash` 掉，
回到 `31eb73d7`（任务 ①–⑤ 之后），单独跑 `FoldRuntimeTests` **同样挂死**（420 秒无输出）。

同时 `FoldRuntimeTests/foldTrace()` 在全量运行里失败，是**竞态**：
trace 是 fire-and-forget 的 `Task { ... }`，测试读到事件时那些 Task 可能还没跑。
机器负载越高越容易触发——这解释了它为什么在这次全量运行里冒出来。

两条都属于既有问题，本任务不碰。

### 2. `AITerminalMirror.post` 没有活的调用方

agent 跑的命令**不会再镜像到终端里**了——工具循环走的是 `AgentRuntime`，
那条路径不调 `AITerminalMirror.post`。命令只出现在 chat 面板里。

死代码 `mirror()` 被删之前，这是仓库里唯一的调用方。

---

## 与基线的对比

| 运行 | 通过 | 失败 |
|---|---|---|
| baseline（原始代码） | 796 | 17 |
| 任务 ①②④⑤ 之后 | 848 | 17 |
| **任务 ③ 之后** | **855** | 16 |

+7 = 本次新增的 5 项解析测试 + 2 项守卫改造后新增的断言。

失败集合相对原始 baseline 的变化：

- `AgentTraceEventTests/ring()` —— **新出现，但单独跑通过**。它断言的是
  `DecisionTraceRecorder.shared` 这个**全局共享** ring 的条数；全量并行时别的测试
  往同一个 ring 里写，条数就不是 2 了。既有竞态，与本次改动无关
  （本次没有碰 trace recorder）。
- `FoldRuntimeTests/foldTrace()` —— 这次**通过了**。上一次全量运行里失败，
  同样是 trace 的竞态（fire-and-forget 的 `Task { ... }` 还没来得及跑）。
- `TeamSSHHostKeyPinningTests/secondConnectionToTheSameHostSucceeds()` —— 既有 flaky
  （实测 baseline 1/6 失败，本次 1/9，**失败率相同**）。

测试隔离复查：全量运行期间用 Quartz 采样，**14 次采样，0 次出现测试宿主在屏窗口**。

---

## 一个守卫被改强，而不是改弱

删除死代码后，`AgentToolMessageWiringTests/remoteOutputUsesUntrusted()` 失败了——
它断言的是**死代码里的那一行字符串**。

没有简单删掉这个断言。改成了一条更强的规则：

> **除了 `AgentRuntime.swift`，agent 目录下任何文件都不得构造 tool message。**

原来那条断言只能对**永远不会执行的代码**通过或失败；新的这条对**任何以后长出
tool message 的文件**都成立。死代码里那份"自己的信任判断"，正是这条规则要挡住的东西。

变异验证：把一条 `ToolMessage.` 塞回别的 agent 文件（`MUTATION-N`）→ 守卫必须失败。
实测：`remoteOutputUsesUntrusted()` 失败，其余 5 项通过。

| 变异 | 期望 | 实际 |
|---|---|---|
| **N**：在 `AgentToolExecutor.swift` 里加一处 `ToolMessage.untrusted(...)` | 指定门必须失败 | ✅ `remoteOutputUsesUntrusted()` 失败，其余 5 项通过 |
