# 任务 ⑭：MCP 客户端

> 对应报告 `docs/agent-capability-gap.md` 的 **P1-1**。
> 日期：2026-10-22
> 状态：完成

---

## 问题

P1-1 的原话是「**MCP —— 完全缺失**」✗：全仓检索 `mcp` 零命中 ✗。

Bonk 的 agent 循环跑在**本地** ✓（模型调用在本地 ✓，工具执行走 SSH 到远端 ✓），
而用户已有的 MCP server（数据库、监控、工单）通常也跑在**本地** ✓。
所以本地 MCP server 对 Bonk 是**直接可达**的 ✗——不需要什么"反向通道" ✓。

> 报告里说"需要先设计本地 server + 远端 agent 的通道" ✗。查过代码之后：
> agent 循环是本地的（`AgentRuntime` 在 app 进程里 ✓，`run_command` 才走 SSH ✓），
> 所以 stdio 传输**不需要**额外通道 ✓。真正需要通道的是"**远端** MCP server" ✗，
> 那是以后的事 ✗。

---

## 参照实现的分层

照 Pi 的 `packages/mcp`（**零 pi 依赖** ✓，只有 `cross-spawn` ✓）：

```
protocol/  types.ts · jsonrpc.ts · content.ts     ← 协议形状
transports/ transport.ts · stdio.ts · in-memory.ts ← 怎么传
client.ts                                        ← 请求怎么发
```

Bonk 的对应：

| Pi | Bonk |
|---|---|
| `protocol/types.ts` | `MCP/MCPProtocol.swift` |
| `protocol/jsonrpc.ts` | `MCP/MCPJSONCoding.swift` |
| `transports/transport.ts` | `MCP/MCPTransport.swift`（协议 + 内存传输 ✓） |
| `transports/stdio.ts` | `MCP/MCPStdioTransport.swift` |
| `client.ts` | `MCP/MCPClient.swift` |
| — | `MCP/MCPTool.swift`（接到 agent 的工具协议 ✓） |
| — | `MCP/MCPServerConfiguration.swift` + `MCPServerRegistry.swift` |

**传输无关是重点** ✓：client core 不知道字节是怎么走的 ✓，
所以测试可以用内存传输跑**真的 client core** ✗（不起子进程 ✓、不占端口 ✓）✓。

---

## 关键设计决定

### 一、信任线画在哪

MCP server 的东西分两类 ✗：

| 是什么 | 来自谁 | 信任类别 |
|---|---|---|
| server 的**身份、工具清单、参数 schema** | 用户自己的配置文件 ✗ | **配置** ✓ |
| 工具**运行时吐出来的数据** ✗ | server 连着的系统 ✗ | **不可信** ✓（走 envelope ✓） |

这和技能那条线不一样 ✓：技能文件在**远端主机**上 ✗（用户未必控制 ✗）→
正文是 `guidance` ✓；MCP server 是**用户自己配的本地程序** ✓ →
它的清单是配置 ✓，但它的输出仍然是数据 ✓。

**模型永远不能决定跑哪个 server** ✗：配置文件在**运行之外**读 ✓
（和技能清单一样 ✓）✗，模型说什么都加不了 server、改不了命令 ✗。

### 二、名字要验

server 报的**工具名**会进模型眼前的工具清单 ✓，还会进模型发出来的调用 ✓。
一个带空格、带换行、带 `; rm -rf /` 的名字 ✗ 不是名字 ✗，
是往名字该在的位置塞文本 ✓ —— 所以**不合规的工具根本不注册** ✓。

server 的名字（来自配置文件 ✓）也走同一套校验 ✓（多一层保险 ✓）。

工具名的格式 `mcp__<server>__<tool>` ✓ —— 前缀保证 server 的工具
**不可能**冒充 app 自己的工具 ✓（`mcp__github__run_command` ≠ `run_command` ✓）。

### 三、每个请求都有截止时间

server 收了调用不回答 ✗ → agent 的这一轮就永远开着 ✗。
所以每个请求都带截止时间 ✓（握手 15 秒 ✓，工具调用 60 秒 ✓）✗，
**连接断了**的时候，所有等着的调用一起失败 ✓ ✗（而不是等截止时间 ✗）。

截止时间**由客户端自己管** ✓：定时器**直接握着这次调用的 slot** ✓，
不经过"应答查得到的那张表" ✓。所以即使应答丢了 ✓（见第七节 ✗），
这一次调用仍然**在截止时间结束** ✓，而不是永远等着 ✗。

> 这一点是变异 M7 逼出来的 ✗：原来的写法是"两个任务赛跑"——
> 一个等应答 ✗，一个等超时 ✗。超时那一边先跑完 ✗，
> 但任务组要**等所有子任务** ✗，而等应答那一边**永远不结束** ✗——
> 于是超时**根本没有生效** ✗：调用挂死 ✗，整个测试进程跟着挂 ✗。

### 四、schema 的类型要还原

agent 的工具参数是**文本** ✓。MCP 的 schema 说参数其实是 number / boolean / object ✓，
所以发出去之前按 schema 把文本还原回类型 ✓ ✗——否则模型完全填对了，
server 却收到 `"42"` 而不是 `42` ✗，然后报一个莫名其妙的错 ✓。

### 五、斜杠不转义

**这条是测试逼出来的** ✗。`JSONSerialization` 默认把 `/` 转义成 `\/` ✓，
于是发出去的方法名是 `tools\/call` ✗ —— JSON 意义上没错 ✓，
但**按原文匹配**的 server 就认不出来了 ✓。

```swift
JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
```

### 六、进程要跟 app 一起死

MCP server 是子进程 ✓。关 stdin 是礼貌的做法 ✗，
不理的就 SIGTERM ✓，再不理就 SIGKILL ✓。
子进程会**尽量**放进自己的进程组 ✓，这样 `npx` 这种 wrapper
不会把真正的 server 留在后台 ✓。

### 七、三个真 bug（都是变异逼出来的）

**丢掉的应答** ✗。客户端原来先发请求 ✗，**再**登记等待应答的 continuation ✗。
应答可以在请求上线的**一瞬间**就回来 ✗ —— 那时 continuation 还没登记 ✗，
应答被丢掉 ✗，请求只能等到截止时间 ✗。

症状不是"慢" ✗，是**间歇性超时** ✗：应答先到还是先登记 ✗，看调度 ✗。
本机负载高的时候必现 ✗（负载 25 ✗ 时两次基线跑各挂 2 个 ✗）。

修法：**先登记，再发** ✗。

```swift
pending[identifier] = slot   // 先登记
Task { try await self.transport.send(wire) }   // 再发
```

这条有**源码顺序门禁** ✗（顺序就是那个不变量 ✗，时序才是那个竞态 ✗）。

**死了的连接让新请求等满截止时间** ✗。连接断了以后 ✗，
新发的请求**登记**的时候 ✗，那个"连接已死"的事实已经过去了 ✗——
于是这个请求一直等 ✗，等到截止时间 ✗（工具调用 60 秒 ✗）✗。

修法：客户端**记住**连接已经没了 ✗，之后的新请求**立刻失败** ✗。

登记和"连接已死"的检查都在 actor 上 ✗ → 串行 ✗ → 两个里总有一个看见 ✗。

**丢了应答的那一次调用永远结束不了** ✗。上面两条修完之后 ✗，
"先登记再发"保证应答**不会丢** ✗——但保证只在**顺序对**的时候成立 ✗。
把登记那一行去掉 ✗（变异 M7 ✗），应答就丢了 ✗，
而**截止时间也救不回来** ✗：截止时间是"两个任务赛跑" ✗，
任务组要**等所有子任务** ✗，等应答那一边永远不结束 ✗ →
超时那一边的结果**发不出去** ✗ → 调用挂死 ✗ → 整个测试进程挂 ✗。

修法：截止时间**不再赛跑** ✗，而是**定时器直接握着这次调用的 slot** ✗，
到点就把 slot 用超时错误结束掉 ✗。这样"应答丢了"和"应答还在路上"
是**同一件事** ✗：都在截止时间结束 ✓。

这一条顺带把门禁的形状改对了 ✗：以前 M7 只能靠源码顺序门禁抓 ✗，
现在它还会让**行为门禁**失败 ✓（调用在截止时间失败 ✗ 而不是挂死 ✗）。

---

## 改了什么

| 文件 | 改动 |
|---|---|
| `Bonk/Services/Agent/MCP/MCPProtocol.swift` | 新增：协议版本、JSON 值、JSON-RPC 消息、工具描述 |
| `Bonk/Services/Agent/MCP/MCPJSONCoding.swift` | 新增：JSON 编解码 + 消息解析 |
| `Bonk/Services/Agent/MCP/MCPTransport.swift` | 新增：传输协议 + 内存传输 |
| `Bonk/Services/Agent/MCP/MCPStdioTransport.swift` | 新增：子进程传输（按行分帧 ✓） |
| `Bonk/Services/Agent/MCP/MCPClient.swift` | 新增：握手、列工具、调工具 + **自己管截止时间** ✓（定时器握着 slot ✓） |
| `Bonk/Services/Agent/MCP/MCPTool.swift` | 新增：接到 agent 的工具包装 + 名字校验 + 类型还原 |
| `Bonk/Services/Agent/MCP/MCPServerConfiguration.swift` | 新增：`~/.bonk/mcp.json` 的读法 |
| `Bonk/Services/Agent/MCP/MCPServerRegistry.swift` | 新增：起 server、收工具 |
| `Bonk/Services/Agent/AgentToolExecutor.swift` | agent 路径起 server、注册工具 |
| `Bonk/State/BonkAppDelegate.swift` | 退出时关掉 server |
| `BonkTests/MCPClientTests.swift` | 新增：24 个测试 |

---

## 配置

`~/.bonk/mcp.json`：

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_TOKEN": "…" }
    }
  }
}
```

格式和 Claude Code 的一致 ✓，省得用户再学一遍 ✓。

---

## 验证

### 测试数

```
requested == executed == 26
failed == 0
skipped == 0
```

### 行为门禁

| 门禁 | 断言的是 |
|---|---|
| `theHandshakeHappens` | 握手发生 ✓，版本谈定 ✓，`notifications/initialized` 发出 ✓ |
| `anUnknownVersionIsRefused` | server 说了客户端不认识的版本 → **拒绝** ✓ |
| `theToolsAreListed` | 工具清单拿得到 ✓ |
| `aToolIsCalled` | 调用能通 ✓，答案能回 ✓ |
| `aFailingToolIsReportedAsSuch` | 工具**自己**失败 ≠ 调用失败 ✓ |
| `aServerErrorIsReported` | server 的错误码原样上报 ✓ |
| `aSilentServerDoesNotHoldTheTurn` | server 不回答 → **截止时间**结束等待 ✓（有看门狗 ✓，不会挂住 ✓） |
| `theDeadlineEndsTheCall` | 结束等待的是**截止时间本身** ✓（不是取消 ✗，不是传输错误 ✗） |
| `aDeadConnectionFailsTheCall` | 连接断了 → 等着的调用失败 ✓ |
| `aRequestAfterDeathFailsAtOnce` | 连接断了**之后**发起的请求**立刻**失败 ✓（不等截止时间 ✓） |
| `theWaiterIsInPlaceBeforeTheRequest` | **源码顺序门禁** ✓：等待者先登记 ✗，请求后上线 ✓ |
| `aRealSubprocessSpeaksTheProtocol` | **真的子进程**（`/bin/sh` 脚本 ✓）走完整个协议 ✓ |
| `theNameIsChecked` | 不合规的名字被拒 ✓ |
| `theNameCannotCollide` | server 的工具冒充不了 app 的工具 ✓ |
| `theTypesComeBack` | schema 的类型被还原 ✓ |
| `theConfigurationNamesTheServers` | 配置文件被正确读 ✓ |
| `aBrokenServerIsSkipped` | 一个坏 server 不影响别的 ✓ |
| `theModelIsShownTheServersTools` | **模型真的看得见** server 的工具 ✓（跑的是生产路径 ✓） |
| `theAgentPathWiresTheServers` | **源码形状门禁** ✓：生产路径起 server 并注册工具 ✓ |

### 两次门禁没抓住的地方

**M6 原来抓不住** ✗。第一版的 M6 门禁是**读源码的形状门禁** ✗：
它只检查 executor 里有没有 `toolRegistry.register(tool)` 这几个字 ✗。
把循环改成 `where false` ✗，这几个字**还在** ✗ → 门禁**照样通过** ✗。

这正是 AGENTS.md 说的那种弱门禁 ✗："数赋值 ✗、数调用 ✗、看结构 ✗" ✗。

修法：加一条**行为门禁** ✗ —— 真的跑一遍生产的 tool loop ✓，
用一个会**记录工具定义**的 provider ✓，
断言模型看到的那份清单里有 `mcp__<server>__<tool>` ✓。
这是**边界** ✓：模型看得见的工具清单 ✓。
M6 现在由这条门禁抓住 ✓（源码形状门禁仍然留着 ✓，它是**接线**的证据 ✗）。

**M8 原来也抓不住** ✗。第一版的 M8 用例用的内存传输 ✗，
peer 死掉以后 `send` **直接抛错** ✗ → 请求**照样立刻失败** ✓ →
把"连接已死就立刻失败"那段去掉 ✗，用例**照样通过** ✗。

修法：换一个**写侧还开着**的传输 ✗（`SwallowingTransport` ✗）——
peer 死了但管道还收写 ✓ → 请求发出去 ✓，**没人回答** ✗。
这时"立刻失败"只能来自客户端**自己记住**连接已死 ✓，
去掉那段就真的要等满截止时间 ✓ → 门禁抓得住 ✓。

### 对抗性变异

| 变异 | 拿掉的东西 | 必须失败的测试 | 结果 |
|---|---|---|---|
| M1 | 工具名的校验 | `theNameIsChecked` | ✓ |
| M2 | 协议版本的校验 | `anUnknownVersionIsRefused` | ✓ |
| M3 | 请求的截止时间 | `aSilentServerDoesNotHoldTheTurn` | ✓ |
| M4 | 参数类型的还原 | `theTypesComeBack` | ✓ |
| M5 | 按行分帧 | `aRealSubprocessSpeaksTheProtocol` | ✓ |
| M6 | 生产路径注册工具 | `theModelIsShownTheServersTools` | ✓ |
| M7 | 先登记再发（把登记那行去掉 ✗） | `theWaiterIsInPlaceBeforeTheRequest` | ✓ |
| M8 | 死了的连接立刻失败 | `aRequestAfterDeathFailsAtOnce` | ✓ |

每次变异都是 `executed == 26` ✓（`requested == executed` ✓）、`failed == 0` 的基线之外 ✓、
`skipped == 0` ✓、没有 host error ✓。

### 全量套件跑出来的两个问题

**测试漏了一个子进程** ✗。接线那条用例真的起了一个 MCP server ✓，
但**没关** ✗ → 那个 server 一直活到测试进程退出 ✗。
全量套件里它把测试进程**吊住**了 ✗（第一次全量跑就挂在这儿 ✗：
`sample` 显示主线程在 `XCTWaiter` 等 ✗，
而一个 `bonk-mcp-wiring-*/server.sh` 还活着 ✗）。

修法两处 ✓：用例自己 `shutdown()` ✓；**registry 析构时带走它的 server** ✓
（`deinit` 里 `terminateNow()` ✓）——"没人要的 server 不该活着" ✓。

**一个既有测试被新用例带崩** ✗。`AgentTraceEventTests/ring` ✓
用的是**全局单例** `DecisionTraceRecorder.shared` ✓，
而别的用例（凡是自己解析 provider 的 ✓）同时往里写 ✓ →
它断言的**绝对计数** ✗ 就被别的用例改掉了 ✗（`router.selected → 3` ✗）。

这不是本任务引入的缺陷 ✗，但本任务让它的概率变高了 ✗。
修法：那条用例改用**自己的 recorder** ✓（actor 有默认 init ✓）✓，
计数不再受别的用例影响 ✓。

### 全量套件

```
passed == 1007
failed == 17
skipped == 10
```

17 个失败**全部**落在既有 baseline 的失败集合里 ✓
（SFTP / bench-linux 缺席 ✓、时序敏感的契约测试 ✓）；
baseline 里那两条 `AgentCommandDeadlineTests` 这次通过了 ✓（时序敏感 ✓）。
10 个 skipped 还是 bench-linux 缺席 ✓。

---

## 还没做的

- **OAuth**（CC 的 `auth.ts` 2,465 行 ✗）—— v1 只有 stdio ✓
- **Streamable HTTP 传输** ✗——传输协议已经留好位置 ✓
- **resources / prompts** ✗——agent 只需要工具 ✓
- **远端 MCP server** ✗——那才是需要"反向通道"的那种 ✓
- **设置界面** ✗——v1 走配置文件 ✓
- **server 的 `tools/list_changed` 通知** ✗——现在忽略 ✓
