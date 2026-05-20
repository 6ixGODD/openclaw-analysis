# OpenClaw 源码深度分析

这组文档面向想读懂 OpenClaw 源码的人：先建立全局模型，再沿着 Gateway、agent runtime、插件/通道、安全和状态数据几个主轴进入实现。它不是用户手册的改写，而是把公开 docs 的行为描述和 `src/`、`extensions/`、`packages/` 中的实现边界绑定起来。

建议阅读顺序：

1. [第 1 章：整体架构](architecture.md)：OpenClaw 的控制平面、运行时平面、插件平面、客户端平面如何组合。
2. [第 2 章：源码地图](source-map.md)：按目录说明核心职责和适合继续深读的入口文件。
3. [第 3 章：Gateway 运行机制](gateway-runtime.md)：启动、认证、WebSocket/RPC、插件 bootstrap、HTTP/Control UI、配置热更新。
4. [第 4 章：Agent 运行机制](agent-runtime.md)：session、workspace、prompt、模型选择、工具策略、重试、流式输出。
5. [第 5 章：插件与通道机制](plugins-and-channels.md)：manifest、activation planner、registry、SDK、channel plugin、共享 `message` tool。
6. [第 6 章：安全分析](security.md)：信任模型、Gateway auth、DM/群组访问、工具和 sandbox、SSRF、Secrets、插件供应链。
7. [第 7 章：状态与数据流](state-and-data.md)：配置、credentials、sessions、transcripts、runtime snapshots、事件和缓存边界。
8. [第 8 章：记忆、上下文与压缩机制](memory-context-compaction.md)：`MEMORY.md`、memory tools、memory-core、context engine、compaction、memory flush、dreaming。
9. [第 9 章：多 Agent 协同与 Subagent 机制](multi-agent-collaboration.md)：agent scope、bindings、session key、workspace/auth 隔离、subagent spawn、thread binding、handoff。
10. [第 10 章：架构亮点与风险点](architecture-highlights.md)：值得学习的设计，以及继续审计时应优先看的薄弱面。
11. [第 11 章：Final Summary](final-summary.md)：对本轮源码绑定分析的最终归纳。

## 资料边界

本文档主要使用本仓库的源码和 docs：

- 产品入口：`README.md`
- 公开架构：`docs/concepts/architecture.md`
- agent runtime：`docs/concepts/agent.md`
- session：`docs/concepts/session.md`
- Gateway 安全：`docs/gateway/security/index.md`
- sandbox：`docs/gateway/sandboxing.md`
- plugin internals：`docs/plugins/architecture.md`
- streaming：`docs/concepts/streaming.md`
- threat model：`docs/security/THREAT-MODEL-ATLAS.md`
- memory：`docs/concepts/memory.md`, `docs/concepts/memory-search.md`, `docs/concepts/memory-builtin.md`
- context engine：`docs/concepts/context-engine.md`
- compaction：`docs/concepts/compaction.md`
- multi-agent：`docs/concepts/multi-agent.md`
- subagents：`docs/tools/subagents.md`

对应的线上入口是：

- https://docs.openclaw.ai/start/getting-started
- https://docs.openclaw.ai/concepts/architecture
- https://docs.openclaw.ai/concepts/agent
- https://docs.openclaw.ai/concepts/session
- https://docs.openclaw.ai/gateway/security
- https://docs.openclaw.ai/gateway/sandboxing
- https://docs.openclaw.ai/plugins/architecture
- https://docs.openclaw.ai/concepts/streaming
- https://docs.openclaw.ai/concepts/memory
- https://docs.openclaw.ai/concepts/memory-search
- https://docs.openclaw.ai/concepts/context-engine
- https://docs.openclaw.ai/concepts/compaction
- https://docs.openclaw.ai/concepts/multi-agent
- https://docs.openclaw.ai/tools/subagents

没有把互联网传闻作为事实来源。若线上 docs 和本地 `docs/` 有差异，应以当前 checkout 的源码与本地 docs 为准。

## 核心结论

OpenClaw 是一个本地优先的个人 AI Gateway，而不是单纯聊天机器人。它把多通道消息接入、agent session、模型/工具运行、远程 node、Control UI、插件能力和安全策略集中到一个长驻 Gateway 中。

最重要的源码边界有四个：

- Gateway 是控制平面：入口在 `src/gateway/server.ts` 和 `src/gateway/server.impl.ts`。
- Agent turn 是运行时主路径：入口在 `src/agents/pi-embedded-runner.ts` 和 `src/agents/pi-embedded-runner/run.ts`。
- 插件是能力所有权边界：入口在 `src/plugins/loader.ts`、`src/plugins/types.ts`、`src/plugins/activation-planner.ts`。
- 通道是插件化消息边界：核心 contract 在 `src/channels/plugins/types.plugin.ts`，实现多数在 `extensions/<id>/`。
- 记忆不是隐藏状态，而是 workspace 文件、索引、memory plugin 和 context engine 共同完成的显式机制。
- 多 Agent 不是多个 Gateway，而是同一个 Gateway 下按 agent id、workspace、agentDir、session key、bindings 隔离出来的多套运行上下文。

读源码时不要先从某个 Telegram/Slack 插件开始。先看 Gateway 如何启动插件、agent 如何消费工具和通道、通道如何把外部消息变成 session，再回到具体插件，路径会清晰很多。
