# 任务 ④：Agent 路径的信任边界

> 对应报告 `docs/agent-capability-gap.md` 的 **P0-3**。
> 状态：进行中
> 日期：2026-10-21

---

## 问题

Ask 路径早就把这件事修过了。`RemoteTerminalState.swift` 的文件头写着理由：

> `system` 是承载权威的角色，所以任何放进那里的远端字节，都会被当成产品自己说的话。

`SystemPromptComposer` 因此把请求拆成**两个独立字段**（`systemPrompt` / `untrustedContext`），
远端字节作为**独立的 user 角色消息**送出，system prompt 里只放"规则"。

Agent 路径被留在了旧形态上。`AgentContextProvider` 返回**一整条拼好的字符串**，
runtime 直接把它拼进 system prompt：

```swift
// 改动前 Bonk/Services/Agent/Runtime/AgentRuntime.swift:149-153
let envContext = await contextProvider.assembleContext(input: input)
var basePrompt = AgentPrompts.toolSystemPrompt
if !envContext.isEmpty {
    basePrompt += "\n\n## Environment Context\n\(envContext)"
}
```

而这个 provider 能装的东西包括：**终端屏幕、工作目录、命令历史、选中文本、git status** ——
全部是远端派生。

也就是说：**Ask 路径的第二扇门，直接开在权威角色里。**

当时只是**潜伏**——生产代码只传了一个 `hostInfo`（主机显示名，本地用户自己起的），
所以没有任何远端字节真的进去过。但接口形状本身在邀请这个缺陷：
任何一次"给 agent 加上终端上下文"的改动，都会直接把它变成活跃漏洞。

---

## 范围

### 做

1. `AgentContext` —— 按来源拆成 `trusted` + `remote: RemoteTerminalState?`
2. `AgentContextProvider.assembleContext` 返回 `AgentContext`
3. `DefaultAgentContextProvider` —— 只有主机显示名是 trusted，其余全部走 `RemoteTerminalState`
4. `RemoteTerminalState` 新增 `gitStatus` 通道（按该文件自己的规矩："Adding a channel? Add it here."）
5. `AgentRuntime` —— trusted 进 system prompt；remote 作为 user 角色消息送出
6. agent 的 system prompt 带上 `RemoteTerminalState.trustPolicy`（规则那一半）

### 不做

- 生产路径仍然只传 `hostInfo`（`AgentToolExecutor.swift:52`）。给 agent 接上真实的终端上下文
  是**另一件事**，得先想清楚"哪些字段可以进上下文"，不属于这次。
- Ask 路径不动（它已经是对的）。

---

## 关键设计决定

| 决定 | 理由 |
|---|---|
| **拆成两个字段，不是加约定** | 交出"一整条拼好的字符串"再要求调用方别往里塞远端字节，就是当初出事的那个约定。拆开之后，要让远端内容进权威角色，必须手工把字符串重建一遍——这在 diff 里看得见 |
| **remote 半边用 `RemoteTerminalState` 承载** | 该类型是"远端派生"的声明处。它的 `untrustedBlock()` 是唯一的渲染方式，所以 agent 路径和 Ask 路径共用同一套标记与清洗 |
| **system prompt 加 `trustPolicy`** | 规则和数据分开：prompt 说"遇到这条消息怎么办"，数据在消息里。Ask 路径已经是这个形状 |
| **远端状态不进会话历史** | 它是**此刻**的状态，不是对话的一轮。下一轮读到一份过期的终端状态，会把它当成"有人说过的��" |
| **git status 走 multi-line 处理** | 分支名、commit subject 是远端选的文本；和 scrollback 一样按数据块渲染 + 剥标记 + 限长 |

---

## 验收结果

### 测试执行证据

| 项 | 值 |
|---|---|
| 指定套件 | `BonkTests/AgentContextTrustBoundaryTests` |
| requested | 9 |
| executed | 9 |
| failed | 0 |
| skipped | 0 |

### 对抗性变异

| 变异 | 期望 | 实际 |
|---|---|---|
| **F**：runtime 把 remote 半边拼进 system prompt（**还原原缺陷**） | 指定门必须失败 | ✅ `systemMessageHasNoRemoteBytes()` 失败，其余 8 项通过 |
| **G**：provider 把远端内容归类成 trusted | 指定门必须失败 | ✅ `providerClassifiesByProvenance()` 失败，其余 8 项通过 |
| **H**：runtime 直接丢弃远端状态 | 指定门必须失败 | ✅ `remoteStateStillReachesTheModel()`、`remoteStateIsMarkedUntrusted()` 失败 |

三次变异后均从**保存的原始副本**恢复（md5 逐个核对），未使用 `git checkout --`。

### 门选在哪一层

`AgentRuntime.executeLoop` 组装 system prompt，`modelGateway.chat(messages:tools:)` 收到结果。
**模型网关收到的消息数组就是生产决策边界**——它字面上就是模型会看到的东西。

所以行为测试驱动真实的 `AgentRuntime`，配一个敌意的 `AgentContextProvider`，
断言落在网关收到的数组上，而不是落在 context 对象上：
断言 context 对象的话，runtime 根本不用它，测试照样绿。

除了"远端字节不在 system 里"，还必须断言**数据仍然到了模型**（在 system 之外）。
只断言前者，一个把所有东西都扔掉的实现也能通过——那等于什么都没证明。

### 与基线的对比

| 运行 | 通过 | 失败 |
|---|---|---|
| baseline（原始代码） | 796 | 17 |
| 任务 ①② 之后 | 831 | 16 |
| **任务 ④ 之后** | **840** | 16 |

+9 = 本次新增的 9 项测试，全部通过。

失败集合与原始 baseline 的差异只有 `TeamSSHHostKeyPinningTests/secondConnectionToTheSameHostSucceeds()` ——
该测试在 baseline 本身就是 flaky（实测 baseline 1/6 失败，本次改动 1/9 失败，**失败率相同**），
且与本次改动无关（改的是 agent 路径的 prompt 组装，不碰 Team/SSH）。

测试隔离复查：全量运行期间用 Quartz 采样，**10 次采样，0 次出现测试宿主在屏窗口**。
