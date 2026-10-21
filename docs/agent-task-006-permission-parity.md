# 任务 ⑥：两条 agent 路径用同一套权限规则

> 对应报告 `docs/agent-capability-gap.md` 的 **P2-4**。
> 日期：2026-10-21
> 状态：完成

---

## 问题

Bonk 有**两条** agent 执行路径，各有各的安全判断：

| 路径 | 判定依据 | 访问模式 |
|---|---|---|
| 工具循环（`AgentRuntime`） | `DefaultAgentPermissionPolicy` | ✅ 读得到 |
| 计划流（`AgentPlanExecutor`） | `step.riskLevel` + `isAutoExecutable` | ❌ **完全没读** |

`AgentPlanExecutor.swift` 里原来是这样写的：

```swift
// Safety check
if step.riskLevel == .blocked { ... 拒绝 ... }
if !step.isAutoExecutable { ... 弹确认框 ... }
```

`step.riskLevel` 是 `CommandSafety.classify(cmd)` 的结果——**确定性的，这没问题**。
问题在于**访问模式一次都没出现**。

而 `AgentEngine.accessMode` 是用户自己设的三档：

| 模式 | 工具循环 | 计划流（改之前） |
|---|---|---|
| **只读** | 改状态的命令 → **直接拒绝** | 弹框问用户 → 用户同意就**执行** |
| **逐步确认** | 改状态的命令 → 弹框 | 弹框（一样） |
| **完全访问** | 改状态的命令 → **直接执行** | 弹框（用户说了"自动"，还是被问） |

**同一条命令，两套规则，取决于走哪条路径。**

两个方向都是坏的：

- 用户设了"只读"，计划流照样问他"要不要删"——他说了不要。
- 用户设了"完全访问"，计划流照样弹框——他说了不用问。

### 这条路径是活的

不是死代码。工具循环只在**存在能工具调用的 provider** 时才走。
Gemini 这类不能工具调用的 provider 激活时，**计划流就是 agent 路径**。

也就是说：**只读模式对一部分用户根本不生效。**

---

## 范围

### 做

1. `AgentEngine` 增加 `permissionPolicyFactory` 依赖
2. 计划流改为通过这个工厂拿策略，用策略判定每一步
3. 工具循环也改为通过同一个工厂拿策略（原来是直接 `DefaultAgentPermissionPolicy(accessMode: AgentEngine.accessMode)`）
4. `AgentEngine.accessMode` 改为 `nonisolated`（它只读一个 preference，线程安全）

### 不做

- 不改三档模式本身的语义
- 不改 `CommandSafety` 的分类规则
- 不改折叠（fold）路径——折叠仍然只在"需要确认"的步骤上生效

---

## 关键设计决定

| 决定 | 理由 |
|---|---|
| **策略用工厂注入，不用实例** | 访问模式是用户可以在聊天开着的时候改的设置。**实例**会在 engine 创建时就把模式定死；**工厂**在每次运行开始时读一次，和工具循环原来的行为一致 |
| **两条路径共用一个工厂** | 同一个 provider 解析的问题（任务 ③）：判定和执行必须问同一个问题。这里是同一个命令必须过同一条规则 |
| **不改 `CommandSafety`** | 风险分级本身是对的，而且两条路径本来就来自**同一个分类函数**（`classifyLevel(cmd) == classify(cmd).level`）。这次改的只是"哪一档访问模式适用于它" |
| **`accessMode` 改成 `nonisolated`** | 它只读 `UserDefaults.standard`，是线程安全的。而工厂是个 `Sendable` 闭包，不能碰主线程隔离的属性 |

---

## 验收结果

### 测试执行证据

| 项 | 值 |
|---|---|
| 指定套件 | `BonkTests/AgentPermissionParityTests` |
| requested | 8 |
| executed | 8 |
| failed | 0 |
| skipped | 0 |

### 行为测试选在哪一层

驱动**真实的 `AgentEngine.runAgent`** → 计划生成 → 批准计划 → `executePlan`，
断言引擎**实际做了什么**：

- 只读 + 改状态命令 → **没有弹确认框，命令没有执行**，步骤记为 blocked
- 完全访问 + 改状态命令 → **没有弹框，命令执行了**
- 逐步确认 + 改状态命令 → **弹了确认框**
- 只读命令 → 三种模式下都直接执行，都不弹框

"命令有没有被执行"是通过执行失败时的消息（`Not connected to any host.` ——
测试里没有真实 SSH）观察到的：没有这条消息，就说明命令**根本没被尝试**。

### 对抗性变异

| 变异 | 期望 | 实际 |
|---|---|---|
| **O**：计划流改回只看 `step.riskLevel`（**还原原缺陷**） | 指定门必须失败 | ✅ `readOnlyRefusesMutatingStep()`、`fullAccessRunsMutatingStep()`、`planPathUsesTheSharedPolicy()` 失败，其余 5 项通过 |

两个方向的门都被抓到，不只是其中一个——只读和完全访问是**两个独立的缺陷**，
只测一个方向会漏掉另一个。

---

## 顺带记一笔：测试不再需要碰用户设置

访问模式原本只能从 `UserDefaults.standard["ai_agent_access_mode"]` 读。
测试要验证不同模式，就得写用户的真实偏好——**而用户的 Bonk 正在运行**。

改成工厂注入之后，测试注入一个指定模式的工厂，
**一个字节的用户偏好都没动**。这跟任务 ②/⑤ 里那个共享 HTTP stub 是同一类问题：
测试的接缝应该在产品代码里，而不是靠改全局状态来制造场景。

---

## 与基线的对比

| 运行 | 通过 | 失败 |
|---|---|---|
| baseline（原始代码） | 796 | 17 |
| 任务 ①–⑤ 之后 | 848 | 17 |
| 任务 ③ 之后 | 855 | 16 |
| **任务 ⑥ 之后** | **861** | **17** |

失败数与原始 baseline **相同**。相对原始 baseline 的差异只有一条：

- `AgentTraceEventTests/ring()` —— 断言的是 `DecisionTraceRecorder.shared` 这个
  **全局共享** ring 的条数；全量并行时别的测试往同一个 ring 里写，条数就不是 2 了。
  **单独跑通过**。既有竞态，与本次改动无关（本次没有碰 trace recorder）。
- `AgentCommandDeadlineTests/cancellationBeatsDeadline()` —— baseline 就在失败，
  这次通过了。那个 suite 的另一半 `quickCommandUnaffected()` 在第一次全量运行里失败过，
  单独复跑**通过**，且在 stash 掉本次改动的前一个 commit 上也**通过**——
  是一次瞬时失败（紧跟全量运行之后，SSH fixture 的端口/socket 还没释放干净）。

测试隔离复查：全量运行期间用 Quartz 采样，**15 次采样，0 次出现测试宿主在屏窗口**。
