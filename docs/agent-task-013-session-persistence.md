# 任务 ⑬：持久化会话 + 恢复

> 对应报告 `docs/agent-capability-gap.md` 的 **P1-4**。
> 日期：2026-10-22
> 状态：完成

---

## 问题

报告里写的是"无会话持久化 / 恢复"，并指出了一条更要紧的：

> 且持久化的 agent 消息存为 `commandOutput` / `system` role，**没有 `tool_call_id`
> 关联**，因此即使读回来也**不构成合法的 tool-calling history**。

这句是关键。**显示用的对话记录不是模型能用的历史**：

- provider 会拒绝"结果对不上调用"的历史 ✗；
- 所以一份气泡列表**根本发不回模型** ✗。

结果就是：app 一重启，agent 就从零开始——不管侧边栏里那个对话看起来有多完整。

---

## 关键设计决定

### 一、模型的视图和**显示记录分开存**

参考实现只有一份（CC 的 JSONL、Pi 的 entry 树）——UI 渲染的就是模型的那份 ✗。
Bonk 的显示记录已经存在（`AIMessageRecord`）✗，硬把它改成模型的形状 ✗ 会牵动
整个 UI ✗。

所以新开一张表：**`AgentTurnRecord`** ✗ —— 存模型看得见的那份：

| 字段 | 是什么 |
|---|---|
| `roleRaw` | `user` / `assistant` / `tool`（API 的角色 ✗，不是 app 的 ✗） |
| `content` | 模型当时看见的原文 ✓（envelope 也在里面 ✓ — 信任类别因此原样保住 ✓） |
| `toolCallID` | 这条结果回答的是哪一次调用 ✓ |
| `toolCallsJSON` | assistant 那轮要了哪些调用（id / name / arguments ✓） |

分开存还带来一个好处：**压缩（compaction）只重写模型的那份 ✗，一个气泡都不碰** ✓。

新表要**四处**登记 ✗（`AGENTS.md` 写的是三处 ✗，其实还有第四个绊线 ✗）：

1. schema 字面量 ✓；
2. `entityNames` ✓；
3. `StoreSchemaContract.baselineEntityNames` ✓；
4. **`StoreFactoryTests.schemaListIsConsistent` 里的实体个数** ✗ —— 这个数字
   是**故意写死**的 ✗：加一个实体就得改它 ✗，于是"改了一半的迁移"会在这里
   露出来 ✗。

> 第 4 条是这次跑出来的 ✗：`AGENTS.md` 的"三处"少算了一处 ✗。
> 漏掉它不会丢表 ✗（前三处就够了 ✗），但会让那个门禁**一直红着** ✗ —— 一盏
> 永远亮着的警报等于没有警报 ✗。

### 二、历史协议的读写变成 async

`AgentMessageHistory.load()` 以前是同步的 ✗——因为历史只在内存里 ✓。

现在历史可能在**库里** ✗，那么"读"就得等 ✗：一次运行**必须**等 Stored turns
读回来才能开始 ✗，否则它会从一个读到一半的对话开始 ✗。

于是协议的方法变成 async ✗（`load` / `record` / `replaceAll` ✗），runtime 的
调用点跟着加 `await` ✗。

### 三、每次写入都走主线程

SwiftData 的 `ModelContext` 是**线程受限**的 ✗，而 app 的 context 是 app 的那个 ✗。
所以持久化历史的所有写入都经 `MainActor.run` ✗ 落到主线程 ✗。

顺带一个好处：**顺序**是确定的 ✓（主线程上的写入是串行的 ✓），
"模型看到的顺序"不会取决于哪个写入先到 ✗。

### 四、压缩重写模型视图，不动显示记录

`replaceAll` = **删掉旧的几轮 + 写入压缩后的几轮** ✗ ✗。
（追加是不对的 ✗：压缩的意义就是把上下文去掉 ✗，追加等于没压缩 ✗。）

---

## 改了什么

| 文件 | 改动 |
|---|---|
| `Bonk/Models/AI/AgentTurnRecord.swift` | 新增：模型视图的一轮 |
| `Bonk/Models/AI/AIConversationRecord.swift` | 新增 `agentTurns` 关系（级联删除 ✓） |
| `Bonk/Services/Store/BonkStore.swift` | schema 字面量 + 实体名清单（两处登记 ✓） |
| `Bonk/Services/Agent/Runtime/PersistentAgentMessageHistory.swift` | 新增：落在库里的历史 |
| `Bonk/Services/Agent/Runtime/AgentMessageHistory.swift` | 协议的方法变 async |
| `Bonk/Services/Agent/Runtime/AgentRuntime.swift` | 读写历史都 await |
| `Bonk/Services/Agent/AgentToolExecutor.swift` | 有会话和库时用**持久化**历史 |
| `BonkTests/StoreSchemaContract.swift` | 契约清单加一项 |
| `BonkTests/AgentSessionPersistenceTests.swift` | 新增：9 个测试 |

---

## 验证

### 测试数

```
requested == executed == 30
failed == 0
skipped == 0
```

### 行为门禁

| 门禁 | 断言的是 |
|---|---|
| `aConversationComesBack` | **重启后**（新的 context、重新 fetch 的会话 ✓）每一轮都回来了 ✓，assistant 那轮的**工具调用**也在 ✓ |
| `theToolResultKeepsItsCallID` | 工具结果带着**它回答的那次调用的 id** ✓ |
| `theLoadedHistoryIsLegal` | 读回来的历史**通过 provider 的规则**（投影）✓——结果对不上调用就会被丢掉 ✓ |
| `aHistoryWithoutTheCallIDIsNotLegal` | 规则本身：没有 id 的结果**活不下来** ✓（这就是持久化要防的那件事 ✓） |
| `compactionRewritesTheModelView` | 压缩重写模型的视图，**显示记录一个都不动** ✓ |
| `theSystemPromptIsNotStored` | system prompt 不入库 ✓（它每轮重建 ✓，存一份会把旧主机名钉在今天的 prompt 里 ✗） |

### 对抗性变异

| 变异 | 拿掉的东西 | 必须失败的测试 | 结果 |
|---|---|---|---|
| N1 | 存 `toolCallID` | `theToolResultKeepsItsCallID` | ✓ |
| N2 | 存工具调用 | `theToolResultKeepsItsCallID`（结果对不上调用 ✗ → 投影丢掉 ✗） | ✓ |
| N3 | 读回存的几轮 | `theSystemPromptIsNotStored`（读回来是空的 ✗） | ✓ |
| N4 | 压缩改成追加 | `compactionRewritesTheModelView` | ✓ |
| N5 | 生产路径不用库里的历史 | `productionPathWiresTheHistory` | ✓ |

> N2 和 N3 抓到的门禁不是"我以为的那个" ✗：N2 让结果**对不上调用** ✗ →
> 投影把它丢掉 ✗ → 任何断言"结果还在"的门禁都会失败 ✓（所以抓到的是
> `theToolResultKeepsItsCallID` ✗）；N3 让读回来是空的 ✗ →
> `theSystemPromptIsNotStored` 里"只剩一条"的断言失败 ✓。
> **门禁抓到什么不重要，重要的是它抓到了** ✓。

---

## 过程中的一件事

既有的接线门禁 `productionPathWiresTheHistory` ✗ 立刻失败了 ✓——它断言的是
"生产路径把 `agentMessageHistory` 交给 runtime" ✗，而现在交给 runtime 的是
**持久化**的那份 ✗。

这正是那个门禁存在的理由 ✓：形状变了 ✗，门禁就该说话 ✗。
改法不是放宽断言 ✗，而是把断言**改成新的不变量** ✗——生产路径必须用**能跨重启
的那份**历史 ✓。

---

## 还没做的

- **会话树**（Pi 的 `parentId` / `context_edit` ✗）：现在是**一条线** ✗，
  分叉和"把某一轮从上下文里剔除但保留在历史里" ✗ 都没有。
- **决策记忆持久化**（`AgentDecisionMemory` ✗）：批准过什么、重启即失 ✗。
- **操作日志持久化**（`OperationLog` ✗）：内存最近 50 条 ✗。
- **非 agent 路径**（Ask / 计划流 ✗）仍用内存历史 ✗。
