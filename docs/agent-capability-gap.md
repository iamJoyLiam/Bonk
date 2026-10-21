# Bonk AI Agent 能力差距报告

> 对比基准：Bonk 现有实现 × Claude Code（泄露源码静态分析） × Pi agent（`@earendil-works/pi` monorepo）
> 日期：2026-10-21
> 方法：三份代码库逐文件读取，所有结论标注 `file:line`。凡"缺失"结论均已检索确认，非推断。
> 参考源：`~/Downloads/claude-code-analysis-main`（1902 文件 / 513,237 行）、`~/Downloads/pi-main`（13 包 monorepo）

---

## 0. 结论摘要

Bonk 的 Agent **是一个结构良好的单轮工具循环器（tool loop），不是一个 agent**。

它已经具备成熟 agent 的**安全骨架**：四级命令危险度分类（L0–L4）、三档访问模式、确认折叠机制、
信任边界封装（`ToolOutputEnvelope`）、输出守卫、预算控制器、终止守卫。这些是这个仓库真正的资产——
比 Claude Code 的很多早期实现都严谨。

但它缺的不是安全，是**能力面与状态面**：

| 维度 | 状态 | 一句话 |
|---|---|---|
| 对话记忆 | **已修复** (任务 ①-A) | 模型上下文每轮从 `[system, user]` 重建 → 已加会话级历史 |
| 旗舰 provider | **已修复** (任务 ②) | Claude 是默认 provider，但 `toolCall` 抛 `not enabled yet` → 已实现 Anthropic `tool_use` |
| agent 信任边界 | **已修复** (任务 ④) | 远端派生上下文被拼进 system prompt → 已按来源拆成 trusted / remote |
| 输出 token 预算 | **已修复** (任务 ⑤) | 每轮硬截断 2000 → 已统一到一个解析点（最差的两条原本只有 500） |
| agent 流式 | **已修复** (任务 ⑧) | `stream` 存在但没有生产调用者 → 已实现带工具的流式轮次 |
| 进度可见 | **已修复** (任务 ⑨) | 模型看不到自己进行到第几步 → 已加任务清单工具 |
| 授权作用域 | **已修复** (任务 ⑩) | 授权没有主机作用域 → 已按主机 UUID 作用域化，并加持久化 allowlist |
| provider 解析 | **已修复** (任务 ③) | 判定看 active、执行看 routed → 一次解析；工具循环原本对一部分用户不可达 |
| 扩展生态 | **P0 缺失** | MCP / Skills / 插件 三者全无，全仓零命中 |
| 并发与委派 | **P1 缺失** | 工具严格顺序执行；无子 agent |
| 持久化与恢复 | **P1 缺失** | transcript 只在内存；持久化会话不是合法 tool-calling history |
| 可扩展授权 | **P1 缺失** | 无 allowlist、无 "always allow"，同类命令每次重新弹窗 |

### 顺手查出来的、报告里原本没有的问题

这几条不是"能力差距"，是**做上面那些事时撞见的缺陷**，记在这里免得丢：

| # | 问题 | 证据 | 状态 |
|---|---|---|---|
| N-1 | 路由器会**静默改掉用户当前选中的 provider** | `AgentEngine.swift:140` `activeProvider = provider` | 已记录，未修（改它会影响路由行为） |
| N-2 | agent 跑的命令**不再镜像到终端** | `AITerminalMirror.post` 只被死代码调用 | 已记录，未修 |
| N-3 | `FoldRuntimeTests` **单独跑会挂死** | 在 `31eb73d7`（本任务 stash 掉）上同样挂死 | 已证明是既有问题，未修 |
| N-4 | `CommandNormalizerTests/sameOperationSameKey` 既有失败 | 原始 baseline 就在失败列表里 | 未动 |
| N-5 | Ask 路径没有项目指令 | 三个入口里两个（Quake 面板、错误诊断面板）不连主机 | 未修 |
| N-6 | trace 是 fire-and-forget，测试读事件变成竞态 | `ConfirmationFoldGate.trace` / `AgentRuntime.traceAgent` 都是 `Task { ... }` | 未修（已让多条测试时好时坏） |
| N-7 | 取消测试在断言前**不等中断落地** | `AgentRuntime.cancel` 用游离 `Task { await executionManager.cancelActive() }` 派发中断，断言可能先跑到 | 已修（断言不变，改为有界等待；见任务 ⑪ 记录） |

**关键判断**：Bonk 当前缺的不是"再写一个工具"，而是**状态机**——没有跨轮次的消息历史、没有可回放
的会话、没有可声明的工具装载、没有可持久化的授权决策。这四样东西缺一，agent 就只能是 loop。

**规模对照**（诚实说明差距）：

| | Bonk | Pi | Claude Code |
|---|---|---|---|
| 核心 agent 代码 | 6,013 行 Swift（34 文件） | 2,519 行 TS（agent core, 6 文件） | `query.ts` 68KB 单文件 |
| 上层 harness | 9,362 行（Agent+AI 服务） | 76,024 行（coding-agent, 254 文件） | 513,237 行（1902 文件） |
| UI 层 | 2,923 行（13 文件） | `interactive-mode.ts` 7,127 行单文件 | `main.tsx` 4,683 行 / 804KB |
| 工具数 | 5 | 8 内置 + codemode + MCP + tool_search | 40+ 内置 + MCP + 延迟加载 |

差距是 **10–80 倍**。但 Bonk 的安全内核比 Pi（完全无内置权限系统）更严谨，
比 Claude Code 的分类法更直接可读。**路线应该是"补状态机"，不是"补规模"。**

---

## 1. 三方架构定位（已验证）

### 1.1 Claude Code —— 平台化 agent

单一执行内核 `src/query.ts:241 queryLoop()` 被 REPL / headless / 子 agent / 后台任务 / bridge 共用
（`query.ts:682` 传 `querySource`：`repl_main_thread` / `agent:*` / `sdk` / `compact`）。

```
入口层    cli.tsx:33 (fast-path router) · main.tsx:585 · entrypoints/sdk/ · entrypoints/mcp.ts · bridge/ · remote/
   ↓
执行内核  query.ts:241 queryLoop (while(true) generator, 7 个 continue 站点)
   ↓
工具层    tools.ts:193 getAllBaseTools() + tools.ts:345 assembleToolPool() (内建连续前缀排序，保 prompt cache)
权限层    utils/permissions/permissions.ts:1158 hasPermissionsToUseToolInner() — 10 步有序决策
沙箱层    utils/sandbox/sandbox-adapter.ts (985 行) — macOS seatbelt / Linux bwrap+seccomp
记忆层    memdir/ (8 文件 1736 行) + services/SessionMemory/ + tools/AgentTool/agentMemory.ts
扩展层    utils/hooks.ts (3500+ 行, 27 个 hook 事件) + utils/plugins/ (42 文件) + services/mcp/ (23 文件)
```

**三个值得直接抄的设计**：

1. **权限是脊柱不是补丁**。`Tool.ts:757-769` 的 `TOOL_DEFAULTS` 全部取保守值
   （`isConcurrencySafe: () => false`, `isReadOnly: () => false`）。决策函数是 10 步有序表，
   且 1e/1f/1g 三步**对 `bypassPermissions` 免疫**——safety check 永远要弹窗（`permissions.ts:1252-1253`）。

2. **工具结果是预算对象，不是字符串**。`constants/toolLimits.ts` 定义了 per-tool 声明上限
   （Bash 30K / Grep 20K）、系统上限（50K 字符 / 400K 字节）、**每条 user message 的聚合上限
   200K 字符**（`toolLimits.ts:49`），超限时**落盘**并只给模型预览+路径
   （`utils/toolResultStorage.ts:104-106`，`<persisted-output>` 标签）。

3. **system prompt 有缓存边界**。`constants/prompts.ts:106-115` 的 `SYSTEM_PROMPT_DYNAMIC_BOUNDARY`
   把 prompt 切成静态可全局缓存段与动态段，静态段用 Blake2b 哈希做跨组织缓存前缀。

### 1.2 Pi —— 可编程 harness（与 Claude Code 正交）

Pi 的主张（`README.md:15-21`）：*"Pi is a minimal, extensible agent harness that you can make your own."*
明确不做子 agent、不做 plan mode、不做权限系统（`SECURITY.md:48-56` 把这些列为 out of scope）。

```
telemetry (叶子, 无依赖)
   ↑ ai (StreamFn 传输抽象, 硬契约: 失败不得 throw)
   ↑ agent (agent-loop.ts:163 runLoop, 2519 行, provider-agnostic)
   ↑ coding-agent (76k 行, 内建 8 工具 + 扩展宿主)
codemode (仅依赖 quickjs-wasi, 零 pi 依赖)   mcp (仅依赖 cross-spawn, 零 pi 依赖)
chord → durable → env (实验性: 事务性 / 可崩溃恢复 / 任务图)
```

**三个值得直接抄的设计**：

1. **Prompt 是分节文档，不是字符串**。`core/system-prompt.ts:188-192` 把 prompt 变成
   `<name>…</name>` 的 map，`diffSystemPromptSections()`（`:217-229`）只发变更的 section，
   变更作为 system message 落盘（`docs/session-format.md:80`）。这让 prompt cache 与
   "中途改变工具装载" 两件事同时成立。

2. **工具"暴露度"是一等概念**。五档：`direct` / `model-only` / `codemode` / `deferred` / `hidden`
   （`docs/extensions.md:250-260`）。这是**上下文预算**架构，不是权限架构——
   工具从模型视野里藏起来，靠 BM25 `tool_search` 按需发现。

3. **codemode：模型写程序，而不是发调用**。模型输出 JS 源码，QuickJS-WASM 沙箱里执行，
   嵌套工具调用**不进入 LLM 上下文**，只有脚本输出进入（`packages/codemode/README.md:3`）。
   N 次串行往返 → 1 次。沙箱真实：无 Node API、无文件系统、无网络、无定时器。

### 1.3 Bonk —— 现状

```
UI: AIChatSidebarView.submit() (AIChatSidebarView.swift:636)
  → submitAgentTask (AIChatSidebarView+TargetBar.swift:75)
  → AgentPlanExecutor.runAgent (AgentPlanExecutor.swift:22)
      ├─ UserIntent.parse
      ├─ 能力判定 useToolLoop (AgentPlanExecutor.swift:45-50)
      └─ runAgentToolLoop (AgentToolExecutor.swift:33)
          └─ AgentRuntime.run → executeLoop (AgentRuntime.swift:124-281)
              └─ for iteration in 0..<25 { modelGateway.chat → 顺序执行 toolCalls }
```

工具集（`Runtime/AgentToolRegistry.swift:232-242`，**静态注册，注册方法无生产调用者**）：

| 工具 | 参数 | 实现 | 备注 |
|---|---|---|---|
| `run_command` | `command` | 原样在远端执行 | 有权限分级 |
| `read_file` | `path` | `head -n 200 '<path>' \|\| cat '<path>'` | **无条件 allowed** |
| `search_history` | `query` | `fc -ln -1000 \| grep -i '<q>' \| tail -25` | **无条件 allowed** |
| `inspect_system` | — | `uname -a; uptime; free -h; df -h /` | 无条件 allowed |
| `list_dir` | `path` | `ls -la '<path>'` | 无条件 allowed |

---

## 2. 能力矩阵

图例：`●` 完备 · `◐` 部分/有缺陷 · `○` 缺失 · `—` 该产品明确不做

| 能力 | Claude Code | Pi | **Bonk** | Bonk 证据 |
|---|:--:|:--:|:--:|---|
| **状态与记忆** ||||
| 跨轮次对话历史 | ● | ● | **○** | `AgentRuntime.swift:156` 每轮重建 `[system,user]` |
| 会话落盘 | ● JSONL 树 | ● JSONL 树 | **○** | `AgentTranscriptStore` 仅内存 |
| 会话恢复 / 分支 | ● | ● tree/fork | **○** | 无 resume / 无 checkpoint |
| 文件级长期记忆 | ● memdir 4 层 | ○ (仅 AGENTS.md) | **○** | 全仓无 memdir 概念 |
| 压缩 / 摘要 | ● 9 种策略 | ● | **◐** | `AgentRuntime.swift:465-556` 2 级压缩 |
| Token 计数 | ● 真值+估算 | ◐ 估算 | ◐ 估算 | `TokenEstimator` bytes/4 |
| **工具** ||||
| 工具数量 | 40+ | 8+ | **5** | `AgentToolRegistry.swift:232` |
| JSON Schema | ● zod→JSON | ● TypeBox | ◐ 手写字符串 | `AgentToolRegistry.swift:78-88` |
| 运行时动态注册 | ● | ● | **○** | `register()` 无调用者 |
| 工具暴露度分级 | ● defer/load | ● 5 档 | **○** | — |
| 并行工具执行 | ● 默认 10 | ● 默认并行 | **○** | `AgentRuntime.swift:247` 顺序 for |
| 工具结果预算 | ● 多级+落盘 | ◐ 50KB/2000行 | ◐ 32KB 全局 | `OutputGuard.swift:20-22` |
| Todo / 任务跟踪 | ● TodoWrite | ○ | **○** | 无 |
| **安全** ||||
| 权限决策 | ● 10 步 | — (不做) | ◐ 4工具+1分级 | `AgentPermissionPolicy.swift:34-75` |
| 持久化 allowlist | ● | — | **○** | 无 |
| OS 级沙箱 | ● seatbelt/bwrap | — (OS 委托) | **○** | 无 |
| 信任边界封装 | ● | ◐ | **●** | `ToolOutputEnvelope.swift` |
| Unicode 净化 | ● | ○ | ○ | — |
| **扩展** ||||
| MCP | ● 6 传输 | ● 2 传输+OAuth | **○** | 全仓零命中 |
| Skills | ● 3 级渐进 | ● Agent Skills 规范 | **◐** 2 级（清单 + 按需加载） | `RemoteSkills.swift`：清单在远端，正文是"指引"类信任 |
| Hooks / 插件 | ● 27 事件 | ● ~30 事件 | **○** | — |
| **多智能体** ||||
| 子 agent | ● | ◐ 示例扩展 | **○** | — |
| 后台任务 | ● | ● durable | **○** | — |
| **provider** ||||
| Anthropic 原生 tool_use | ● | ● | **○** | `ClaudeLLMProvider.swift:78` 抛异常 |
| OpenAI Responses API | — | ● | ● | `OpenAIResponsesLLMProvider.swift` |
| 多 provider | ● | ● 27 API | ◐ 5 适配器 | `ClaudeLLMProvider/Gemini/Ollama` 无 toolCall |
| **流式** ||||
| 助手文本流式 | ● | ● | **○** | `AgentModelGateway.stream` 无调用者 |

---

## 3. P0 差距（阻断性）

### P0-1 模型上下文里没有对话历史 —— 最大单一缺口

> **状态：已修复**（任务 ①-A，见 `docs/agent-task-001-message-history.md`）。
> 以下保留原始分析，作为改动前的依据。

**证据**：

```swift
// Bonk/Services/Agent/Runtime/AgentRuntime.swift:156-159
var messages: [LLMMessage] = [
    .system(systemPrompt),
    .user(input),
]
```

每轮 agent 运行都从零重建消息数组。Ask 路径同理（`AgentEngine.swift:364`）。
持久化的 SwiftData 会话（`AIConversationRecord` / `AIMessageRecord`）**只被 UI 读取用于显示**——
全仓 `AIMessageRecord` 的非 Models 引用只有 `AIChatSidebarView.swift:75`、`TerminalAIPanel.swift:46`、
`AIChatMessageBubbles.swift:62`（渲染）与 `AIConversationStore.swift:46`（写入），
**没有任何一处把它读回 LLM 请求**。

唯一的历史构造器 `AgentMessage.toAIMessages()`（`AgentModels.swift:117-131`）
只被 legacy plan 路径使用，且只取 `suffix(20)`。

**后果**：
- 模型无法引用三轮前说过的话（"再试一次那个命令" → 无从知晓）
- agent 无法做多步推理闭环（改配置 → 验证 → 再改）
- 压缩机制（`AgentRuntime.maybeCompact`）在**单轮内**压缩工具输出，
  压缩的却是一段**只包含本轮**的历史——压缩逻辑写得很认真，但压缩的对象是空的

**参照**：
- Claude Code：`query.ts:1716` `messages: [...messagesForQuery, ...assistantMessages, ...toolResults]`
- Pi：`core/session-manager.ts:543 buildSessionProjection()` → `core/agent-session.ts:790` prepareRequest 钩子替换

**修复建议**：`AgentRuntime` 接受一个 `AgentConversationStore` 协议（消息数组 + 持久化），
`messages` 初始为该 store 的投影，与 `AgentTranscriptStore` 合并。
这是**一切其他能力的前置**——没有历史，子 agent、任务跟踪、长任务全是空谈。

---

### P0-2 Claude / Gemini / Ollama 无法使用 Agent 工具循环

> **状态：Claude 已修复**（任务 ②，见 `docs/agent-task-002-anthropic-tool-use.md`）。
> Gemini 与 Ollama 仍然抛 `not enabled yet`（原生协议未实现）。
> 以下保留原始分析，作为改动前的依据。

**证据**：

```swift
// Bonk/Services/AI/Providers/ClaudeLLMProvider.swift:78
throw AIError.unsupported("Claude tool loop is not enabled yet")
// GeminiLLMProvider.swift:76 / OllamaLLMProvider.swift:79 同构
```

而 `AIProviderType.swift:54` 把 `.claude` 列为**默认 provider 类型**，默认模型 `claude-sonnet-5`。
Anthropic 原生的 `tool_use` / `tool_result` block 协议**完全未实现**——
当前只有 OpenAI 的 `tool_calls` / `function_call` 两种 wire format
（`OpenAICompatibleLLMProvider.swift:117-133`、`OpenAIResponsesLLMProvider.swift:117-133`）。

**后果**：旗舰 provider 缺席旗舰功能。用户装 Bonk、用默认 Claude 模型、开 Agent —— 直接报错。

**参照**：Pi 把 `@anthropic-ai/sdk` 放在 `packages/ai` 的第一方依赖里，Anthropic 与 OpenAI 平权。

**修复建议**：在 `LLMProvider` 协议下新增 `toolCall` 的 Anthropic 实现。
Anthropic 的 `tool_use` → `tool_result` 与 OpenAI 的 `tool_calls` → `tool` role 是同构的，
转换层约 100 行，不需要动 agent 循环。

**连带问题**：`AgentPlanExecutor.swift:45-50` 用 `resolveProvider()` 判定是否走 tool loop，
`AgentToolExecutor.swift:43` 又用 `resolveAgentProvider(task:.agentExecute,...)` **重新解析一次**。
两个函数不同、结果可能不一致 → 可能选了 tool loop 却拿到一个 `toolCall` 会抛异常的 provider，
且**无 plan 模式回退**（`AgentErrorCode.modelFailure` 直接结束运行）。
这两个判定必须合并为一次解析。

---

### P0-3 Agent 路径把远端派生上下文拼进 system prompt

> **状态：已修复**（任务 ④，见 `docs/agent-task-004-agent-context-trust-boundary.md`）。
> 以下保留原始分析，作为改动前的依据。

**证据**：

```swift
// Bonk/Services/Agent/Runtime/AgentRuntime.swift:149-153
let envContext = await contextProvider.assembleContext(input: input)
var basePrompt = AgentPrompts.toolSystemPrompt
if !envContext.isEmpty {
    basePrompt += "\n\n## Environment Context\n\(envContext)"
}
```

`DefaultAgentContextProvider.assembleContext`（`Runtime/AgentContextProvider.swift:41-71`）
产出 `### Connected Host` / `### Current Working Directory` / `### Git Repository Status` /
`### Selected Text` / `### Recent Terminal History` / `### Active Terminal Screen`，
其中 terminal screen / cwd / git status / selected text **全部是远端派生字节**。

这与本项目自己立的规矩**直接冲突**：

- `RemoteTerminalState.swift:1-33` 的文件头注释定义了"远端字节不得进入 authority role"的原则
- `AgentEngine.swift:534-557` `SystemPromptComposer.compose` 返回 `(systemPrompt, untrustedContext)`
  **两个独立字段**，Ask 路径守住了这条边界
- `BonkTests/AgentSystemPromptProductionWiringTests.swift` 用真实 `AgentEngine.execute` +
  敌意 `TerminalContext` 断言"远端字节不得进入 system role"

**但是**：该守护测试只覆盖 **Ask 路径**，**Agent 路径没有任何对应测试**。

**当前是潜在（latent）而非活跃缺陷**：生产实例只传 `hostInfo`
（`AgentToolExecutor.swift:47-49`），`hostInfo` 是显示名，非远端字节。
但接口 `AgentContextProvider.assembleContext` 一旦接上终端内容就会立刻变成活跃漏洞——
**这是一个被架构邀请的漏洞**。

**修复建议**：
1. `AgentContextProvider` 改为返回 `(trusted: String, untrusted: String)`，与
   `SystemPromptComposer` 保持同一形状
2. 远端派生部分一律经 `ToolOutputEnvelope.untrusted` 包装，作为 `.user` 角色消息注入
3. 新增 `AgentSystemPromptProductionWiringTests` 的 agent 路径对偶用例

---

### P0-4 单轮输出被硬截断到 2000 token

> **状态：已修复**（任务 ⑤，见 `docs/agent-task-005-output-token-budget.md`）。
> 实际比报告记录的更糟：五个不同的默认值散落在代码里，同一个模型取决于走哪条路径
> 预算就不同，最差的两条只有 **500 token**（约 350 词），长回答被从中间截断。
> 以下保留原始分析，作为改动前的依据。

**证据**：

```swift
// Bonk/Services/Agent/Runtime/AgentModelGateway.swift:28
maxTokens: nil
// Bonk/Services/AI/Providers/OpenAICompatibleLLMProvider.swift:122
let resolvedMaxTokens = maxTokens ?? config.maxOutputTokens ?? 2000
```

网关**永远传 nil**，于是除非用户在 provider 配置里显式设置 `maxOutputTokens`，
每一轮 agent 对话都被限死 2000 输出 token。对推理模型（Claude reasoning / o-series），
这 2000 会先被隐藏 reasoning 吃掉，可见文本骤减。

**参照**：Claude Code `utils/context.ts:149-210 getModelMaxOutputTokens()` 按模型给
8K（默认）/ 32K / 64K / 128K，并有每轮一次的 escalation 机制（`query.ts:1188-1221`）。

**修复建议**：默认值改为按 provider 能力表取值；引入"输出被截断则自动续写"的恢复路径。

---

## 4. P1 差距（重要）

### P1-1 MCP —— 完全缺失

全仓检索 `mcp` / `model context protocol`（`*.swift` / `*.rs` / `*.md` / `*.toml` / `*.json`，
排除 `build/` `bonk-win/` `website/`）→ **零命中**（唯二 repo 级命中是
`bonk-win/package-lock.json` 里的 sha512 子串）。

Bonk 是 SSH 终端，**MCP 恰恰是最贴合的扩展点**：用户已有大量 MCP server
（数据库、监控、工单、CMDB），Bonk 的终端场景下 MCP server 通常跑在**本地**，
而 Bonk 的 agent 跑在**远端主机**——这是一个 Claude Code 和 Pi 都没覆盖的组合：
**本地 MCP server + 远端 SSH 目标**。

参照实现规模：
- Claude Code：`services/mcp/` 23 文件 12,994 行，6 种传输 + OAuth（`auth.ts` 2,465 行）
- Pi：`packages/mcp` **零 pi 依赖**（仅 `cross-spawn`），传输无关核心 + stdio + Streamable HTTP
  + 内存传输；协议版本 `2025-11-25`；OAuth 含 PKCE / 动态客户端注册 / token 刷新

**建议**：照 Pi 的分层做——传输无关的 client core + 独立的 stdio/HTTP transport，
工具命名 `mcp__<server>__<tool>`。**注意一个 Bonk 独有的设计约束**：
MCP server 在本地，agent 在远端，因此工具调用需要经 SSH 通道反向送达本地。
这需要先设计"本地 MCP 代理"通道，不要假设 MCP server 跑在远端。

### P1-2 Skills / 插件 / Hooks —— 全部缺失

> **状态（2026-10-21）：Skills 已实现**，见 `docs/agent-task-011-skills.md`。
> Hooks 与插件仍未做。
>
> 实现要点与本节建议的出入：技能落在**远端主机的家目录**
> `~/.bonk/skills/<name>/SKILL.md`（不是项目目录——exec 通道的工作目录不是
> 用户 cd 到的目录）；列表在**循环之外**读（app 自己的读不是模型的命令）；
> 列表的分段标记带**每次运行随机的 nonce**，所以技能文件无法伪造分段；
> 技能的正文是**指引**（第三类信任 `guidance`），不是 raw 输出，也不是权威。

Bonk 唯一的 "plugin" 是终端主题插件（`Bonk/Themes/ThemeRegistry.swift:24-27`），与 agent 无关。

**渐进式披露**（Claude Code `src/tools/SkillTool/prompt.ts:21-29` 的三级预算）：

| 级别 | 进入上下文的内容 | 预算 |
|---|---|---|
| L1 列表 | name + description + whenToUse | `contextWindow × 4 × 0.01`，回退 8,000 字符 |
| L2 加载 | 模型调用 `Skill` 工具后才注入全文 | per-tool 100,000 字符 |
| L3 检索 | 实验性后台预取 | — |

Pi 实现了 [Agent Skills 规范](https://agentskills.io/specification)（`docs/skills.md:7`），
同样三级：`core/skills.ts` 校验 name（≤64 字符，`^[a-z0-9-]+$`）/ description（≤1024 字符），
prompt 里只放 name+description+path，模型按需读 `SKILL.md`。

**Bonk 适配建议**：SSH 场景下 skill 的"文件"应落在**远端主机**，且 `SKILL.md` 应能通过
`read_file` 类工具读取——Bonk 现有的 `read_file` 已经具备这个能力，**基础设施已在位**。

### P1-3 无子 agent、无并行工具执行

```swift
// Bonk/Services/Agent/Runtime/AgentRuntime.swift:247
for toolCall in response.toolCalls {
    switch await runToolCall(toolCall, ...) { ... }
}
```

严格顺序。全 agent 树里只有一个 `withThrowingTaskGroup`，且是与本问题无关的
`withTimeout` 辅助函数（`AgentEngine.swift:501`）。

参照：
- Claude Code：`services/tools/toolOrchestration.ts:8-12` 默认并发 **10**；
  `partitionToolCalls()`（`:91-116`）把连续并发安全工具分批，
  **非并发安全工具单独成批**；若 `isConcurrencySafe` 抛异常则**保守视为不安全**（`:103-105`）
- Claude Code 还有流式执行器 `StreamingToolExecutor.ts:40`——工具在模型**还在流式输出时**就开始执行
- Pi：`packages/agent/src/agent-loop.ts:516-521` 默认并行，
  预检（校验 + `beforeToolCall`）顺序执行，**执行**并发（`:646-648`）

**建议**：先做并行（同一条 assistant 消息里的多个 tool call），
再做子 agent（因为子 agent 需要 P0-1 的历史支撑）。

**Pi 的一个值得抄的细节**（`agent-loop.ts:478-503`）：若响应因 `length` 截断，
该消息里**所有** tool call 一律不执行，因为流式参数是"尽力 JSON 抢救"解析出来的，
可能"能解析能校验但静默不完整"。Bonk 当前没有这个保护。

### P1-4 无会话持久化 / 恢复

| 层 | 存储 | 可恢复 |
|---|---|---|
| `AgentTranscriptStore` | 内存 `[AgentEvent]` | 否 |
| `AgentState` | 内存（每次运行） | 否 |
| `AgentDecisionMemory` | 内存 actor（跨运行） | 否——重启即失 |
| `OperationLog` | 内存最近 50 条 | 否 |
| UI 会话 | SwiftData | **仅显示** |

且持久化的 agent 消息存为 `commandOutput` / `system` role，**没有 `tool_call_id` 关联**
（`AgentToolExecutor.swift:132-141`），因此即使读回来也**不构成合法的 tool-calling history**。

参照：
- Claude Code：`utils/sessionStorage.ts` 5,105 行，JSONL，`parentUuid` 链 + `logicalParentUuid`；
  侧链 agent transcript 单独存 `agent-<agentId>.jsonl`；`MAX_TRANSCRIPT_READ_BYTES = 50MB`
- Pi：`docs/session-format.md` —— **session 是树不是日志**（`id`/`parentId`），
  `context_edit` 支持追溯性地把某条 entry 从模型上下文中剔除但保留原始历史；
  compaction 是一条 **entry** 而非一次突变

### P1-5 无持久化 allowlist / "always allow"

> **状态：已修复**（任务 ⑩，见 `docs/agent-task-010-host-scoped-allowlist.md`）。
> 实际查出**两个**问题：授权**从来没有按主机分作用域**（决策记忆的键只有命令，
> 于是一台主机上的批准会跟着折叠门跑到另一台主机去），以及没有持久化规则。
> 两条都修了：作用域是主机 UUID，规则只回答"要不要问"、不越过拒绝，
> 规则形状照抄参考实现（只有 `动词 + 子命令` 才给前缀）。

`DefaultAgentPermissionPolicy` 每次都从零判定。同样一条 `docker ps`，
用户今天批准了，明天还要重新批准。

Claude Code：`permissions/PermissionRule.ts:25-40` 的规则格式 `"ToolName"` 或 `"ToolName(content)"`，
来源含 `SETTING_SOURCES` / `cliArg` / `command` / `session`，持久化在 settings.json。
并且 `permissions.ts:1268` 的 bypass 模式、`:1284` 的整工具 allow 规则、`:1300` 的 passthrough
构成完整的优先级表。

**Bonk 的位置特殊**：agent 跑在**远端主机**，授权是"对这台远端机的授权"，
allowlist 应当按 `(host, command)` 二元组作用域化，且不应泄露到本地。

### P1-6 `CustomInstructions` 读错了文件系统

> **状态：已修复**（任务 ⑦，见 `docs/agent-task-007-remote-project-instructions.md`）。
> 改法：指令改从**远端主机**的工作目录读，作为 user 角色消息（Claude Code 的形状），
> 不进 system prompt；远端工作目录严格转义，远端输出不能伪造框架。
> **Ask 路径暂未接入**（三个入口里两个没有主机），见遗留清单 N-5。

```swift
// Bonk/Services/Agent/CustomInstructions.swift:20
let cwd = directory ?? FileManager.default.currentDirectoryPath
```

三个调用点（`AgentRuntime.swift:154` 等）**全都不传 `directory:`**，
因此读的是**本地 Mac 进程的工作目录**。对 bundle 打包的 `.app`，cwd 是 `/`，
所以 `.bonk/instructions.md` / `AI_INSTRUCTIONS.md` **在实践中永远加载不到**。

这正好卡在最有价值的位置上：Bonk 是 SSH 终端，**项目指令应该在远端主机上**，
而且应该能被 `read_file` 按需拉取（Claude Code / Pi 都是这个模型：
AGENTS.md 放索引，内容按需读）。

**建议**：远端优先——从远端 cwd 探测指令文件；退化为本地只读（仅当用户显式要求）。

### P1-7 Agent 循环不流式

> **状态：已修复**（任务 ⑧，见 `docs/agent-task-008-agent-streaming.md`）。
> 不只是"打开一个开关"：流式的一轮必须**同时带工具调用**，
> 所以新增了能流式带工具的线协议解析（OpenAI 系 + Anthropic），
> 以及一个不能就返回 nil 的 provider 缝（行为不变，只是不流式）。
> 顺带关掉 P2-3（reasoning 现在有发射者了）。

`AgentModelGateway.stream`（`AgentModelGateway.swift:36-42`）存在但**无生产调用者**。
agent 循环用 `modelGateway.chat`（非流式）——用户在整轮结束前看不到任何东西。

流式是 agent UX 的分水岭。Claude Code 在 `query.ts:659-708` 的流里同时做：
回填字段（克隆上做，避免破坏 prompt cache 的字节一致性，`query.ts:748-787`）、
错误保留（可恢复错误先扣住，恢复失败才抛，`query.ts:799-825`）、
**工具边流边执行**（`query.ts:841-843`）。

Pi 的 `AssistantMessageEvent` 协议每个事件都带 `partial`
（`packages/ai/src/types.ts:806-816`），TUI 直接消费 `message_update`。

### P1-8 无进度向模型可见

> **状态：已修复**（任务 ⑨，见 `docs/agent-task-009-agent-task-list.md`）。
> 给模型一个任务清单工具（`todo_write`）：模型自己写、自己更新，
> 清单对它可见、对用户可见。顺带关掉 P2-1。

`AgentState.progress` 有 `completedSteps` / `failedSteps` / `lastExitCode`，
但**模型永远不知道自己进行到第几步**。Claude Code 有 `TodoWriteTool` + `TaskCreate/Get/Update/List`，
Pi 的 durable 有 task graph。

---

## 5. P2 差距

| # | 项 | 证据 |
|---|---|---|
| P2-1 | 无 todo / 任务跟踪工具 | 全仓 `todo\|tasklist\|TaskTool` 零命中 | ✅ **已修复**（任务 ⑨）：`todo_write` 工具 |
| P2-2 | 无工具结果缓存 | `Services/Agent/` 内 `cache` 零命中；同一命令每次重跑 |
| P2-3 | 无 reasoning 展示 | `AgentEvent.thinking`（`Runtime/AgentEvent.swift:43`）存在，**没有任何代码发出它** | ✅ **已修复**（任务 ⑧）：流式轮次里两种线协议的 reasoning 都会送到 |
| P2-4 | 两套并行安全流水线 | tool loop 用 `DefaultAgentPermissionPolicy`；legacy plan 用 `CommandSafety.classify` + `isAutoExecutable`（`AgentPlanExecutor.swift:231-266`）。同一命令两套规则 | ✅ **已修复**（任务 ⑥）：计划流改走同一个 `DefaultAgentPermissionPolicy`，三档访问模式两条路径都生效 |
| P2-5 | 死代码 | `runToolIteration` / `executeToolCalls`（`AgentToolExecutor.swift:166-272`，无调用者）；`AgentTools.definitions`（单工具 legacy schema）；`AgentToolRegistry.register`（无调用者）；`AgentModelGateway.stream`（无调用者）；`AgentEngine.buildAgentMessages`（仅 legacy 一处） |
| P2-6 | 压缩对象为空 | `maybeCompact`（`AgentRuntime.swift:465-556`）逻辑完整（stale 输出收缩 + 中段摘要 + 压缩次数上限 5），但因 P0-1 它压缩的是单轮历史 |
| P2-7 | 无 Unicode 净化 | Claude Code `utils/sanitization.ts:25` 对零宽 / bidi override / 私用区做 NFKC 归一化迭代，**并应用于 MCP 输出**（`services/mcp/client.ts:96`）。Bonk 的 `ToolOutputEnvelope` 做的是 marker 剥离，不是字符净化 |
| P2-8 | Windows 端 mock 回落违反本仓安全不变量 | `bonk-core/src/ai/mod.rs:49-53`：`api_key` 为空时返回 `[mock <model>] <prompt>` **作为成功**。`bonk-win/src-tauri/src/main.rs:521-534` 把 `unwrap_or_default()` 的空 key 喂进去，注释自认"真连 + mock 回落"。**macOS 应用不走这条路径**（`bonk-mac-ffi/Sources/BonkCoreFFI` 只有 SSH 桥，无 AI 导出），故为 Windows-only。违反 AGENTS.md "Production paths MUST NOT convert real infrastructure failures into successful mock results" |

---

## 6. 建议路线图

### 阶段一：补状态机（阻断项，必须先做）

顺序不能颠倒——每一项都依赖前一项。

**状态：5 项全部完成。**

| # | 事项 | 触及文件 | 完成判据 | 结果 |
|---|---|---|---|---|
| 1 | **消息历史存储**：引入 `AgentConversationStore` 协议，`AgentRuntime` 从它初始化 `messages` | 新建 `Runtime/AgentConversationStore.swift`；改 `AgentRuntime.swift:156` | 第二轮能引用第一轮的变量名；跨重启仍在 | ✅ 任务 ①-A（会话级，内存；持久化留给阶段二第 7 项） |
| 2 | **Anthropic tool_use 实现** | `AIProvider.swift` 协议；新 `Providers/AnthropicToolUseLLMProvider.swift` | Claude provider 下 agent 循环可用 | ✅ 任务 ②（`AnthropicToolWire.swift` + `ClaudeLLMProvider.toolCall`） |
| 3 | **合并 provider 解析** | `AgentPlanExecutor.swift:45-50`、`AgentToolExecutor.swift:41` | 判定与执行用同一 provider；不可用时回退 plan 模式 | ✅ 任务 ③（一次解析；顺带删掉带自己安全流水线的死代码） |
| 4 | **agent 路径信任边界** | `AgentContextProvider.swift:41-71`、`AgentRuntime.swift:149-153` | 远端字节不进入 system role；有 mutation 测试 | ✅ 任务 ④（按来源拆成 trusted / remote） |
| 5 | **输出 token 按模型取值** | `OpenAICompatibleLLMProvider.swift:122`、`AgentModelGateway.swift:28` | 推理模型不被 2000 截断 | ✅ 任务 ⑤（实际更糟：最差的两条路径原本只有 500） |

### 阶段二：能力面

| # | 事项 | 参照 | 备注 |
|---|---|---|---|
| 6 | **并行工具执行** | `toolOrchestration.ts:91-177`；`agent-loop.ts:516` | 先做并行，再做子 agent |
| 7 | **持久化会话 + 恢复** | Pi 的 JSONL 树（`docs/session-format.md`）；CC 的 `sessionStorage.ts` | 必须含 `tool_call_id`，否则不是合法 history |
| 8 | **MCP 客户端** | `packages/mcp`（零依赖、传输无关） | **需先设计"本地 server + 远端 agent"的通道**——这是 Bonk 独有的，CC/PI 都没这个组合 |
| 9 | ~~**Skills**~~ ✅ | `core/skills.ts` + `docs/skills.md` | 2026-10-21 完成，见 `docs/agent-task-011-skills.md`；指令文件在远端 |
| 10 | **allowlist（host+command 作用域）** | `PermissionRule.ts:25-40` | 按远端主机作用域化，不下沉到本地 |
| 11 | **流式输出** | `query.ts:659-708`；`AssistantMessageEvent` | 顺带接上 `AgentEvent.thinking` |
| 12 | **Todo / 任务跟踪工具** | `TodoWriteTool` | 成本最低、感知收益最高 |

### 阶段三：护城河（Bonk 独有）

这三项是 CC 和 Pi 都没做的，是 Bonk 的差异化机会：

1. **跨主机协作 agent** —— Bonk 已有 `TeamRelay` / `TeamGuestTerminalView` / `SessionManager+SplitPane`，
   把多主机 agent 编排接上去
2. **本地 MCP server × 远端 SSH 目标** —— 上一条 P1-1 的通道设计
3. **codemode 式"脚本即工具"** —— 在远端跑 QuickJS/WASM 沙箱，让模型写程序而不是发调用，
   把 N 次 SSH 往返压成 1 次。Bonk 的 SSH 往返延迟比本地高得多，**这个收益比 CC/PI 大**

---

## 7. 照搬会踩的坑

| 坑 | 说明 |
|---|---|
| **别把 Claude Code 的复杂度整体搬过来** | `src/utils/` 18 万行 / 564 文件，`main.tsx` 804KB，`feature('X')` 编译期裁剪大量代码路径导致外部构建**无法执行**其中相当一部分。Bonk 应抄机制，不抄规模 |
| **别照抄 Claude Code 的 `auto` 权限模式** | `yoloClassifier.ts` 1,495 行，把安全决策交给模型分类器（fail-closed 但仍是概率性组件）。Bonk 的 L0–L4 分类法更直接可读，**保留自己的** |
| **别照抄 Pi 的"无权限系统"** | `SECURITY.md:48-56` 把沙箱、prompt injection 列为 out of scope。Bonk 是**远程执行**场景，风险面比 Pi 的本地场景大得多，权限系统必须留在核心 |
| **别把 Pi 的 durable 直接搬** | `packages/durable/README.md:3` 自述 *"Experimental. The API changes without notice between releases."*，且与 `coding-agent` 概念大量重复（两套 `edit.ts`/`write.ts`/`read.ts`/`bash.ts`） |
| **别把工具结果上限做成全局固定值** | CC 用 per-tool 声明 + 系统上限 + **每条 message 聚合上限**三层（`toolLimits.ts`）；Pi 统一 2000 行/50KB 但与模型上下文大小无关。Bonk 远端带宽有限，分级策略更值钱 |
| **别在远端跑不可信脚本** | codemode 的 QuickJS 沙箱前提是本地；若在远端执行模型写的代码，需要的是远端宿主侧的沙箱（seatbelt/bwrap），不是 WASM |
| **别把 Claude Code 的 `bypassPermissions` 语义照搬** | CC 的 1e/1f/1g 三步是 **bypass-immune** 的（`permissions.ts:1252-1253`）。Bonk 若引入 bypass 模式，必须保留等价的不可绕过检查 |

---

## 8. 附录：证据索引

### 8.1 Bonk 关键文件

| 文件 | 行数 | 角色 |
|---|---|---|
| `Bonk/Services/Agent/Runtime/AgentRuntime.swift` | 854 | agent 循环、上下文组装、压缩、权限授权 |
| `Bonk/Services/Agent/Runtime/AgentToolRegistry.swift` | 261 | 5 个工具定义与实现 |
| `Bonk/Services/Agent/Runtime/AgentPermissionPolicy.swift` | 76 | 权限策略 |
| `Bonk/Services/Agent/Runtime/AgentContextProvider.swift` | 72 | 环境上下文组装（P0-3 源头） |
| `Bonk/Services/Agent/Runtime/AgentModelGateway.swift` | ~45 | 模型网关（P0-4 源头） |
| `Bonk/Services/Agent/CommandSafety.swift` | 712 | L0–L4 分类器 |
| `Bonk/Services/Agent/ToolOutputEnvelope.swift` | 202 | 信任边界封装 |
| `Bonk/Services/Agent/AgentPlanExecutor.swift` | 450 | 入口 + legacy plan 路径 |
| `Bonk/Services/Agent/AgentToolExecutor.swift` | 427 | tool loop 装配 |
| `Bonk/Services/Agent/AgentPrompts.swift` | 77 | system prompt 目录 |
| `Bonk/Services/Agent/CustomInstructions.swift` | 51 | 项目指令加载（P1-6 源头） |
| `Bonk/Services/AI/Providers/ClaudeLLMProvider.swift` | 111 | Claude 适配（P0-2 源头） |

### 8.2 已被证伪的初始假设（留档，避免重复劳动）

- **`read_file` / `search_history` 的 shell 注入**：`AgentToolRegistry.swift:101` 的
  `'` → `'\''` 是**正确的 POSIX 单引号转义**，无法逃逸。**不构成漏洞。**
  （真正的问题是这两个工具被 `AgentPermissionPolicy.swift:36` **无条件 allowed**，
  且其构造出的命令**从不经过 `CommandSafety.classifyLevel` 复检**——
  路径不受作用域限制，可读远端任意路径包括 `~/.ssh/id_rsa`。
  这是**授权作用域缺失**，不是注入。）
- **Rust `bonk-core/src/ai/mod.rs` 的 mock 回落影响 macOS**：不成立。
  `bonk-mac-ffi/Sources/BonkCoreFFI` 只有 SSH 桥，**无 AI 导出**；
  该模块仅被 `bonk-win/src-tauri/src/main.rs` 使用。作用域为 Windows-only（见 P2-8）。

### 8.3 外部参考

- Claude Code 分析文档：`~/Downloads/claude-code-analysis-main/analysis/`（中文，18 章）
  ⚠️ 该文档集有 8 处与真实源码不符（见下）
- Pi：`~/Downloads/pi-main`（13 包），根 `README.md` / `AGENTS.md` / `SECURITY.md` / `docs/`

**Claude Code 分析文档与源码的已知出入**（本次逐条复核）：

| # | 文档声称 | 源码实际 |
|---|---|---|
| 1 | `detectAndGetBackend()` 回退到 in-process 后端 | `utils/swarm/backends/registry.ts:136-254` 无 in-process 回退，**无 tmux 直接抛错** |
| 2 | `scrubBareGitRepoFiles(directory: string)` | `utils/sandbox/sandbox-adapter.ts:404` 无参，清理模块级数组 |
| 3 | `tengu_disable_bypass_permissions_mode` 在 killswitch 文件 | 门控串在 `permissionSetup.ts:1266` |
| 4 | `compactConversation` 签名中 `suppressFollowUpQuestions` 在末尾 | 实际在 `customInstructions` **之前**（`services/compact/compact.ts:387`） |
| 5 | 4 种压缩策略 | **至少 9 种** |
| 6 | `DANGEROUS_BASH_PATTERNS` 列表 | 真实列表是其**严格超集**（缺 `python2`/`tsx`/`lua`/`pnpm run`/`bun run` 等） |
| 7 | `buildTool` "fail-closed" | 对 concurrency/read-only/destructive 成立；`checkPermissions` 默认 **allow** |
| 8 | 竞品对比 | 全部引用外部 URL，源码内无验证依据，**属观点非证据** |

---

*本文档所有 Bonk 结论均经本机直接读取源码确认；Claude Code 与 Pi 结论经源码 `file:line` 复核。
标记为"缺失"的项均已执行检索确认。*
