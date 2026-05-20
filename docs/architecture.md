# 第 1 章：整体架构

OpenClaw 的顶层形态是“一个长驻 Gateway + 多个客户端/通道/节点 + 一个嵌入式 agent runtime + 插件能力层”。`README.md` 把它定义为运行在用户设备上的 personal AI assistant；`docs/concepts/architecture.md` 进一步明确 Gateway 是 WebSocket 控制平面，负责消息面、节点、事件和客户端 RPC。

## 1.1 一张结构图

```text
Messaging channels / webhooks / CLI / Control UI / nodes
        |
        v
Gateway HTTP + WebSocket control plane
  - auth, pairing, method scopes
  - session routing, chat state, event broadcast
  - plugin bootstrap and runtime registry
        |
        +--> channel plugins and outbound delivery
        +--> node host commands and device surfaces
        +--> Control UI / WebChat / MCP / HTTP routes
        |
        v
Embedded agent runtime
  - session lane + global lane
  - workspace + prompt context
  - model/provider selection
  - tool catalog + tool policy + sandbox/elevated routing
  - streaming, retry, compaction, failover
        |
        v
Models, tools, filesystem, browser, external APIs, plugins
```

## 1.2 四个平面

| 平面 | 主要职责 | 源码入口 |
| --- | --- | --- |
| 控制平面 | Gateway 启动、认证、RPC、事件、配置 reload、插件 bootstrap | `src/gateway/server.ts`, `src/gateway/server.impl.ts` |
| Agent 运行时平面 | 每个用户 turn 的 session、prompt、模型、工具、重试和输出 | `src/agents/pi-embedded-runner.ts`, `src/agents/pi-embedded-runner/run.ts` |
| 插件能力平面 | 插件发现、manifest、activation、registry、capability registration | `src/plugins/loader.ts`, `src/plugins/types.ts`, `src/plugins/registry.ts` |
| 通道接入平面 | DM/群组消息、allowlist、outbound delivery、channel-specific actions | `src/channels/`, `src/channels/plugins/types.plugin.ts`, `extensions/` |

## 1.3 Gateway 是系统中心

`src/gateway/server.ts` 只有一个薄入口：它懒加载 `server.impl.ts`，避免 CLI 只需要轻量行为时提前导入整个 Gateway。真正启动逻辑在 `startGatewayServer()`，它完成配置读取、runtime config 注入、插件 bootstrap、method registry、HTTP/WS 绑定、post-attach sidecars、配置写入监听等工作。

这个设计和 `docs/concepts/architecture.md` 的行为描述一致：Gateway 是长驻进程，客户端、node、Control UI 和消息通道都连到同一个控制面。它不是“只转发消息”的网关，而是状态和策略的拥有者。

## 1.4 Agent runtime 是 Gateway 内的一条执行管线

`docs/concepts/agent.md` 描述 OpenClaw 使用单个 embedded agent runtime。源码上，`src/agents/pi-embedded-runner.ts` 导出兼容名称，真实实现落在 `src/agents/pi-embedded-runner/run.ts` 的 `runEmbeddedPiAgent()`。

这个函数做的不是简单调用模型：

- 解析或回填 `sessionKey`。
- 把 turn 排进 session lane 和 global lane。
- 解析 workspace、agent dir、agent runtime plan、auth plan。
- 加载 runtime plugins。
- 运行 before-model hooks。
- 选择模型和 auth profile。
- 执行 backend attempt。
- 处理 failover、compaction、空回复、reasoning-only、tool result 过大、流式输出和最终 reply payload。

所以 OpenClaw 的 agent 层更像一个多策略执行引擎，而不是一层 provider SDK wrapper。

## 1.5 插件是能力所有权边界

`docs/plugins/architecture.md` 明确：plugin 是 ownership boundary，capability 是 core contract。源码上，`src/plugins/types.ts` 的 `OpenClawPluginApi` 暴露 `registerProvider`、`registerChannel`、`registerTool`、`registerHook` 等注册点；`src/plugins/loader.ts` 负责把 manifest、配置、enablement、模块加载和注册结果汇聚进 registry。

核心原则是：

- core 不硬编码某个 vendor 或 channel 的实现策略。
- provider/channel/feature 由插件声明所有权。
- core 消费 registry 和 SDK contract。
- 启动路径尽量先读 manifest 和 metadata，少导入重 runtime。

这也是源码中大量 `*.runtime.ts`、public artifact、metadata snapshot、activation planner 存在的原因。

## 1.6 通道是插件化消息边界

通道的核心 contract 在 `src/channels/plugins/types.plugin.ts`。一个 `ChannelPlugin` 可以包含 config、setup、pairing、security、groups、mentions、outbound、status、gateway methods、auth、commands、lifecycle、directory、actions、heartbeat 等 adapter。

## 1.7 一次消息的端到端路径

从外部消息到模型回复，OpenClaw 的主路径可以按所有权拆成六段：

1. channel plugin 接入外部事件。插件负责把 Telegram/Discord/Slack/WhatsApp 等平台的原始 payload 解析成 OpenClaw 能理解的 sender、peer、thread、account、message content、attachments 和 delivery context。
2. routing 层解析 agent。`src/routing/resolve-route.ts` 根据 channel、account、peer、parent peer、guild/team/roles 与 bindings 选择 agent id 和 session key。
3. Gateway 调用 agent method。`src/gateway/server-methods-list.ts` 暴露 `agent` 等 method，method registry 做 scope 校验、参数处理和事件广播。
4. agent runtime 执行 turn。`runEmbeddedPiAgent()` 负责 lane、workspace、bootstrap、runtime plan、model/auth、tools、sandbox、streaming、retry、compaction。
5. 插件能力被按需调用。模型看到的 tool catalog 来自 core tools 和 plugin tools；通道发送、memory search、provider runtime、hooks 都通过 registry/SDK surface 进入。
6. 回复回到 delivery layer。最终输出可能发回原 channel，也可能只更新 session/Control UI，或者交给 subagent completion handoff。

这条路径说明 OpenClaw 的核心不是“channel 插件直接调用模型”，而是 channel 只做边界适配，真正策略集中在 Gateway 和 agent runtime。

## 1.8 控制平面和运行时平面的分工

控制平面关心“能不能、该给谁、怎么登记”：

- 哪些插件被启用。
- 哪些 Gateway method 可以被哪个 scope 调用。
- 哪个外部会话绑定到哪个 agent。
- 哪个 session key 对应哪个 transcript。
- 哪些事件要广播给 UI 或 node。

运行时平面关心“这一 turn 如何执行”：

- 用哪个 workspace 和 bootstrap。
- 用哪个 provider/model/auth profile。
- 暴露哪些工具。
- sandbox/elevated 如何处理。
- prompt 是否过大，是否要 compaction。
- tool result 和 final reply 如何流式输出。

这两个平面不是完全隔离的。比如 plugin loader 属于控制面，但它注册的 provider/tool/channel 会进入运行时；session store 属于控制面状态，但 agent runtime 也会读写 model override、spawn depth、thread binding 等字段。理解这种交叉，是读 OpenClaw 源码时避免迷路的关键。

## 1.9 为什么插件是架构中心

OpenClaw 不是用 plugin 系统做“附加功能”，而是用 plugin 系统定义能力所有权。provider、channel、memory backend、context engine、tools、hooks 都可以是插件注册的 capability。这样 core 可以保持 generic runtime：

- core 不知道 Telegram API 的细节，只知道 channel contract。
- core 不知道某个模型厂商的 auth 细节，只知道 provider runtime contract。
- core 不知道某个 memory backend 的索引结构，只知道 memory host SDK/tool contract。
- core 不知道某个 context engine 的内部 store，只知道 ingest/assemble/compact/afterTurn contract。

这也是为什么源码里会同时存在 `src/plugins/*`、`src/plugin-sdk/*`、`extensions/*` 和大量 `*.runtime.ts` 文件。它们共同把“可发现的能力”和“真正执行的重代码”拆开。

OpenClaw 没有为每个通道在 core 里复制一套发送工具。`docs/plugins/architecture.md` 描述了共享 `message` tool：core 负责 tool host、prompt/session/thread bookkeeping 和 dispatch；通道插件负责 action discovery、capability/schema contribution 和最终执行。

## 1.10 客户端和 node

`docs/concepts/architecture.md` 把客户端分成 Control UI/CLI/web admin 和 node。源码上 Gateway method 和 events 由 `src/gateway/methods/registry.ts`、`src/gateway/server-methods-list.ts` 管理。Node 相关能力散落在 `src/gateway/node-*`、`src/node-host/`、`src/cli/nodes-*` 中。

安全上，node 不是不可信沙箱；它是已经配对到 Gateway 的远程执行面。`docs/gateway/security/index.md` 明确 Gateway 和 node 属于同一 operator trust domain。

## 1.11 关键不变量

- 一个 Gateway owns 当前主机的消息面和状态面。
- `sessionKey` 是路由和上下文选择，不是授权 token。
- 插件 runtime in-process 执行，不是 sandbox。
- sandbox 只包住工具执行，不包住 Gateway。
- 通道入口必须先做 sender/group/DM 策略判断，再进入 agent。
- 配置读取和写入要通过 runtime snapshot、validation、atomic write 和 audit 记录。
- 依赖 provider/channel 的行为必须通过插件 contract 或 SDK seam，而不是 core 深 import。
