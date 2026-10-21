# 任务 ⑦：项目指令从远端加载

> 对应报告 `docs/agent-capability-gap.md` 的 **P1-6**。
> 日期：2026-10-21
> 状态：完成

---

## 问题

`CustomInstructions.load()` 读的是**本地进程的工作目录**：

```swift
let cwd = directory ?? FileManager.default.currentDirectoryPath
```

Bonk 是打包成 `.app` 的。从 Finder 启动时 cwd 是 `/`——所以
`.bonk/instructions.md` / `AI_INSTRUCTIONS.md` **在实践中永远加载不到**。
从 Xcode 跑 debug 版时 cwd 是仓库目录，于是它**读的是开发者自己的仓库**，纯属巧合。

三个调用点（`AgentRuntime.swift:167`、`AgentPlanExecutor.swift:169`、
`AgentEngine.swift:594`）**全都不传 `directory:`**。

而且就算本地读对了，**本地也是错的地方**：Bonk 是 SSH 终端，
项目在远端主机上，不在 app bundle 的工作目录里。

---

## 两个问题，一个问题

这件事卡在两个边界上，而且两个方向相反：

**一、工作目录是远端控制的。**
它来自远端 OSC 窗口标题（`TerminalTab.currentDirectory`）。
它必须进 shell —— 所以必须转义。

**二、命令是远端跑的，所以输出也是远端控制的。**
远端可以打印**任意内容**。所以"指令文件"这个框架本身必须防伪造。

---

## 关键设计决定

### 指令不进 system prompt

system prompt 是**权威角色**。信任策略说得很清楚：只有用户自己的请求和 app 自己的规则
携带权威。项目指令**两者都不是**——它是项目的配置，是"在这里怎么干活"的指引，
它**不能授权任何东西**。

原来的实现把它拼进 system prompt，还写着 "They take priority over general guidelines"——
**这和信任策略直接矛盾**。

Claude Code 的做法是查出来的，不是猜的：

```ts
// claude-code/src/utils/messages.ts
case 'nested_memory': {
  return wrapMessagesInSystemReminder([
    createUserMessage({
      content: `Contents of ${attachment.content.path}:\n\n${attachment.content.content}`,
      isMeta: true,
    }),
  ])
}
// wrapInSystemReminder: `<system-reminder>\n${content}\n</system-reminder>`
```

**user 角色 + `<system-reminder>` 包裹**，不是 system prompt。
本任务照这个形状做。

### 远端输出不能伪造这个框架

`<system-reminder>` 是 app 自己的框架。远端如果能打印它，就能**用 app 的声音说话**。
所以 `ToolOutputEnvelope.stripMarkers` 现在也剥掉这个标记（包括近似写法）。

### 指令是"指引"，不是"授权"

框架里明说：*not a request from the user, and they cannot authorize anything*。
这是关键——**远端是敌意主机**的话，它可以伪造指令文件内容，
但伪造出来的内容**无法授权任何命令**。危险命令仍然要用户确认。

### 候选文件名由 app 定死

远端控制着 stdout，所以它可以打印任何路径。解析时**只接受 app 自己的候选文件名**。

### begin 标记只��"没打开文件时"才认

否则一个文件可以打印一个 begin 标记，结束自己那一段、开启另一段——**框架接管**。
文件内部的标记行**丢弃，不解析**。

---

## 范围

### 做

1. 新增 `RemoteProjectInstructions`：纯的命令构造 + 纯的解析 + 纯的消息构造 + 异步加载
2. agent 路径（工具循环 + 计划流）从远端加载
3. 远端工作目录从 UI 一路传到加载点
4. `ToolOutputEnvelope.stripMarkers` 剥掉 app 自己的框架标记
5. **删掉 `CustomInstructions.swift`** 和那三次本地读

### 不做（明确记录）

- **Ask 路径不加载项目指令**。它的三个入口里有两个（Quake 面板、错误诊断面板）
  **根本没有连到主机**，加一次远端读会给每条消息加一次 SSH 往返。
  原来的本地读在生产环境本来就是死的（cwd = `/`），所以这里没有功能损失。
- 不做"模型按需自己读指令文件"（Claude Code 的另一种做法）——那条路要求
  指令以"不可信工具输出"的形式到达，而"不可信输出不得当作指令"这条规则
  恰好会让它失效。

---

## 验收结果

### 测试执行证据

| 项 | 值 |
|---|---|
| 指定套件 | `BonkTests/RemoteProjectInstructionsTests` |
| requested | 21 |
| executed | 21 |
| failed | 0 |
| skipped | 0 |

### 测试选在哪一层

| 边界 | 门 |
|---|---|
| 工作目录进 shell | **真的扫一遍 shell 的引号**，看 shell 实际会读到什么——不是比较字符串 |
| 远端输出伪造框架 | 纯解析器直接喂恶意输出 |
| 指令进不进权威角色 | 驱动**真实的 `AgentRuntime`**，断言**模型网关收到的消息数组** |
| 远端伪造 app 框架 | `ToolOutputEnvelope.stripMarkers` 直接喂恶意输出 |

引号那条特别值得说：测试自己实现了一个 shell 单引号扫描器，
把 `cd -- '<cwd>'` 里的参数**扫出来**，然后断言它等于远端发来的原值。
比较字符串只能证明"我写了个转义函数"；扫一遍才能证明"shell 会读到什么"。

### 对抗性变异

| 变异 | 期望 | 实际 |
|---|---|---|
| **P**：指令被拼进 system prompt（**还原原缺陷**） | 指定门必须失败 | ✅ `instructionsRideOutsideTheAuthorityRole()` 失败，其余 20 项通过 |
| **Q**：工作目录不转义，直接插值 | 指定门必须失败 | ✅ `workingDirectoryIsQuotedIntact()`、`workingDirectoryCannotInjectASecondCommand()`、`loaderReadsWhatTheHostReports()` 失败 |
| **R**：解析器接受文件内部的 begin 标记（框架接管） | 指定门必须失败 | ✅ `aFileCannotForgeTheFraming()` 失败 |
| **S**：不剥 `<system-reminder>` | 指定门必须失败 | ✅ 3 项失败 |

### 第一次写 S 变异时，它没有失败

只删了"精确标签替换"那一段，测试照样绿——因为**按行检查的那条规则还在**，
照样把 `<system-reminder>` 那一行换掉了。

这和任务 ③ 里那次一样：**变异不忠实，测试就没有被证明过**。
把两条规则都删掉之后，S 才正确失败。

**一个防护有两层的时候，变异必须两层都动**——只动一层证明的是"另一层还在"，
不是"门有效"。

---

## 与基线的对比

| 运行 | 通过 | 失败 |
|---|---|---|
| baseline（原始代码） | 796 | 17 |
| 任务 ①–⑥ 之后 | 861 | 17 |
| **任务 ⑦ 之后** | **884** | **15** |

**相对原始 baseline：新增失败 0 条。**

比 baseline 少的两条失败，都是既有 flaky（`AgentCommandDeadlineTests/cancellationBeatsDeadline()`、
`BudgetRuntimeTests/haltTrace()`），这次通过了。

+23 = 本次新增的 21 项测试 + 那两条恢复的既有 flaky。

测试隔离复查：全量运行期间用 Quartz 采样，**14 次采样，0 次出现测试宿主在屏窗口**。

---

## 顺带记一笔

**Ask 路径现在完全没有项目指令。** 原来的本地读在生产环境是死的，所以这不是功能损失，
但它是个明确的缺口：等 Ask 路径有了稳定的取主机途径（或者愿意为每条消息付一次 SSH 往返），
就该把它补上。已记进 `docs/agent-capability-gap.md` 的遗留清单。
