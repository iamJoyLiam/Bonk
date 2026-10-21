# 任务 ⑩：授权按主机作用域化 + "always allow"

> 对应报告 `docs/agent-capability-gap.md` 的 **P1-5**。
> 日期：2026-10-21
> 状态：完成

---

## 问题

报告里写的是"无持久化 allowlist"。查下来是**两个**问题，其中一个是安全缺陷。

### 一、授权从来没有按主机分作用域

`AgentDecisionMemory` 按**命令**记事实，键就是归一化后的命令：

```swift
let memoryKey = Self.stateKey(tool: toolCall.name, arguments: argsDict)
let history = await decisionMemory?.facts(for: memoryKey)
```

**键里没有主机。** 而这个 memory 挂在 `AgentEngine` 上（单例），所以：

> 用户在主机 A 上批准了 `mkdir /tmp/x`，
> 这个批准在主机 B 上**同样成立**。

而这个 `history` 是**折叠门（fold gate）的输入**——折叠门一旦同意，就**跳过确认框**。
所以这不是"记忆串了"，是**授权串了**。

报告里那句话正是要害：

> Bonk 的位置特殊：agent 跑在**远端主机**，授权是"对这台远端机的授权"。

### 二、没有持久化的 allowlist，也没有"always allow"

`DefaultAgentPermissionPolicy` 每次都从零判定。同一条 `docker ps`，今天批准了明天还要批准。

---

## 关键设计决定

### 作用域是主机，而且是**稳定标识**

规则绑的是主机的 **UUID**，不是显示名——显示名会改、也不唯一。
作用域从 UI 一路传到策略、传到 runtime、传到决策记忆的键。

### 规则回答的是"要不要问"，不是"能不能绕过去"

策略里的顺序：

- **拒绝**（L4 关键命令、只读模式）**永远不被规则翻掉**。
- 规则只把 `.confirmRequired`（要问）变成 `.allowed`（不问）。

只读模式是用户对这台机器的承诺；一条"以后别问"不能把它改掉。

### 规则的形状照抄参考实现

Claude Code 不是随便给个前缀的。它的 `getSimpleCommandPrefix` 只在命令是
**`动词 + 子命令`** 这个形状时才给前缀：

| 命令 | 前缀 |
|---|---|
| `git commit -m "fix"` | `git commit` |
| `npm run build` | `npm run` |
| `rm -rf /tmp/x` | **无**（`-rf` 是 flag，不是子命令） |
| `ls -la` | **无** |
| `cat file.txt` | **无**（文件名不是子命令） |
| `env bash -c evil` | **无**（wrapper） |
| `sudo apt install x` | **无**（wrapper） |

**这一条很要紧**：如果前缀是整条命令的前缀，那么"永远允许 `rm -rf /tmp/build`"
会顺带覆盖 `rm -rf /tmp/build cache`——**那是另一条命令，删得更多**。
前缀只给两段式，`rm` 这种就退化成**整条命令精确匹配**。

wrapper 也要禁：`env bash -c ...` 能跑任意东西，`sudo` 前缀等于自动批准未来的提权调用。

### 链式命令要**每一段**都被覆盖

`docker ps; rm -rf /` 有两段。`docker ps` 的规则对第二段什么也没说，
所以不覆盖整条命令。按整串匹配会让任何东西从只覆盖开头的规则里溜过去。

### 决策记忆的键也带上作用域

这条是修上面那个安全缺陷的。键前面加作用域，中间用一个归一化命令里不可能出现的分隔符。

### 规则存在哪

`UserDefaults`（JSON），和 `ai_agent_max_iterations` 这类 agent 设置放一起——
本就是 agent 设置该待的地方。**不新增 SwiftData 实体**，也就没有迁移风险。

---

## 验收结果

### 测试执行证据

| 项 | 值 |
|---|---|
| 指定套件 | `BonkTests/AgentAllowlistTests` |
| requested | 19 |
| executed | 19 |
| failed | 0 |
| skipped | 0 |

### 四条边界，四个门

| 边界 | 门 |
|---|---|
| 规则只覆盖它该覆盖的 | 纯匹配函数直接喂各种命令形状 |
| 作用域就是主机 | 纯匹配 + 策略 + 决策记忆三层各一道 |
| 规则不越过拒绝 | 策略：只读模式、L4 关键命令 |
| 规则持久 | 用独立的 `UserDefaults` suite 造出"重启后"的第二个实例 |

### 对抗性变异

| 变异 | 期望 | 实际 |
|---|---|---|
| **Z**：忽略主机作用域 | 指定门必须失败 | ✅ `theScopeIsTheHost()`、`noHostMeansNothingIsCovered()`、`anotherHostStillAsks()` 失败 |
| **AA**：决策记忆不带作用域 | 指定门必须失败 | ✅ `decisionsAreRememberedPerHost()`、`aVerdictDoesNotCrossHosts()` 失败 |
| **AB**：规则越过只读模式的拒绝 | 指定门必须失败 | ✅ `aRuleNeverOverridesARefusal()` 失败 |
| **AD**：任何两个词都给前缀 | 指定门必须失败 | ✅ `aPrefixNeedsVerbAndSubcommand()`、`aPrefixIsNeverOfferedForAWrapper()`、`aCommandWithNoPrefixIsKeptWhole()` 失败 |

---

## 与基线的对比

| 运行 | 通过 | 失败 |
|---|---|---|
| baseline（原始代码） | 796 | 17 |
| 任务 ①–⑨ 之后 | 912 | 17 |
| **任务 ⑩ 之后** | **930** | 18 |

失败集合相对原始 baseline 的差异：

- `AgentTraceEventTests/ring()` —— 断言的是 `DecisionTraceRecorder.shared` 这个
  **全局共享** ring 的条数；全量并行时别的测试往同一个 ring 里写，条数就不是 2 了。
  **单独跑通过**。既有竞态。
- `TeamSSHHostKeyPinningTests/secondConnectionToTheSameHostSucceeds()` —— 既有 flaky。
- `FoldPlanStepTests/planTrace()` —— 同族的竞态：trace 是 fire-and-forget 的
  `Task { ... }`，全量并行时 `decisionResolved` 还没落盘测试就读了。
  **单独跑 4/4 通过**。
- `AgentCommandDeadlineTests/cancellationBeatsDeadline()` —— baseline 就在失败，这次通过。

测试隔离复查：全量运行期间用 Quartz 采样，**15 次采样，0 次出现测试宿主在屏窗口**。

---

## 顺带记一笔

**trace 的 fire-and-forget 写法让好几个测试变成竞态。**
`ConfirmationFoldGate.trace` 和 `AgentRuntime.traceAgent` 都是
`Task { await recordAgentEvent(...) }`——测试读到事件时，那些 Task 可能还没跑。
机器越忙越容易触发。

这已经让 `AgentTraceEventTests/ring()` 和 `FoldPlanStepTests/planTrace()`
在不同运行里时好时坏。**不是这次改动造成的**，但它让"全量运行的结果"本身变得不可信——
本次就有两条失败是它。

已记进遗留清单 N-6。
