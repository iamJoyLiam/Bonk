# 任务 ⑨：模型自己维护的任务清单

> 对应报告 `docs/agent-capability-gap.md` 的 **P1-8**（顺带关掉 **P2-1**）。
> 日期：2026-10-21
> 状态：完成

---

## 问题

`AgentState.progress` 记着 `completedSteps` / `failedSteps` / `lastExitCode`，
但**模型永远看不到它**。

模型知道自己在对话里问过什么、回来过什么，然后得**从这些里面推断自己进行到第几步**。
多步骤的任务里，这一步经常推错——尤其是命令失败之后。

Claude Code 的做法是给模型一个**任务清单工具**：模型自己写清单、自己更新。
Pi 的 durable 有 task graph。

---

## 关键设计决定

### 模型写整份清单，不是改单项

`TodoWrite` 每次写**完整**的清单。这是 Claude Code 的形状，也是对的形状：
模型不用去推理一个 diff，一份可能写坏的清单也不会只应用一半。

### 工具只写内存，不碰目标主机

清单存进这一轮运行的内存（`AgentTodoStore`），工具**什么都不执行**。
所以它**不需要确认**——没有东西需要用户批准。

（这一点差点踩坑：`DefaultAgentPermissionPolicy` 对未知工具一律 `confirmRequired`，
所以清单工具一开始会**每写一次弹一次框**。已在策略里显式豁免。）

### 结构化参数要原样送达

工具的 `todos` 参数是一个**数组**。但 runtime 原来的参数转换是：

```swift
let argsDict = toolCall.arguments.compactMapValues { "\($0)" }
```

数组会被转成 Swift 的**数组描述**——那不是 JSON，解析不回来。

改成：字符串参数就是自己，**数组和对象保留 JSON 形式**。
这条改动是通用的，以后任何结构化参数的工具都受益。

### 清单的内容不进"权威"通道

清单是**模型自己写的**，内容可能抄了远端的文本。所以：

- 工具返回的内容走 runtime **既有的** `ToolMessage.untrusted` 通道——和别的工具输出一样，
  不构成新的授权路径。
- 模型读到的是**自己刚写的清单**（工具调用参数本来就在对话里），不需要回声来获得权威。

---

## 验收结果

### 测试执行证据

| 项 | 值 |
|---|---|
| 指定套件 | `BonkTests/AgentTodoToolTests` |
| requested | 12 |
| executed | 12 |
| failed | 0 |
| skipped | 0 |

### 三个边界，三个门

| 边界 | 门 |
|---|---|
| 模型写的清单能被解析 | 纯解析器直接喂各种畸形输入 |
| 结构化参数原样送达 | 驱动真实 runtime，模型发一个**数组**参数的工具调用 |
| 清单不弹确认框 | 驱动真实 runtime，记录有没有 `permissionRequested` |

### 对抗性变异

| 变异 | 期望 | 实际 |
|---|---|---|
| **V**：结构化参数又被压平 | 指定门必须失败 | ✅ `theListReachesTheUser()`、`theListIsStored()`、`theModelSeesItsList()` 失败 |
| **X**：清单存了但不发布 | 指定门必须失败 | ✅ `theListReachesTheUser()` 失败 |
| **W**：清单也要确认 | 指定门必须失败 | ✅ `theTaskListNeverAsks()`、`theToolNeverAsks()` 失败 |

### 变异 W 第一次把测试**挂死了**

清单工具不再豁免确认 → runtime 发出 `permissionRequested` 等用户回答 → 测试没回答 →
**永远等下去**。

这就是 `FoldRuntimeTests` 那个坑的同一形状：**一个会挂死的门，报不出失败。**

改法：测试驱动 runtime 时**顺手批准任何权限请求**，并把"有没有问过"记下来。
于是策略变了 → 测试**失败**而不是挂死。

> 挂死的门比失败的门更糟：它不告诉你任何事，还占着整个测试进程。

---

## 与基线的对比

| 运行 | 通过 | 失败 |
|---|---|---|
| baseline（原始代码） | 796 | 17 |
| 任务 ①–⑧ 之后 | 899 | 18 |
| **任务 ⑨ 之后** | **912** | **17** |

失败数与原始 baseline **相同**。相对原始 baseline 的差异只有一条：

- `TeamSSHHostKeyPinningTests/secondConnectionToTheSameHostSucceeds()` —— 既有 flaky
  （实测 baseline 1/6 失败，本次改动同量级）。
- `AgentCommandDeadlineTests/cancellationBeatsDeadline()` —— baseline 就在失败，这次通过。

测试隔离复查：全量运行期间用 Quartz 采样，**13 次采样，0 次出现测试宿主在屏窗口**。
