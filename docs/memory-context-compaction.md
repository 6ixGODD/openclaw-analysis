# 第 8 章：记忆、上下文与压缩机制

OpenClaw 官网把 memory、context engine、compaction 分成三组概念。源码上它们也确实不是一个东西：memory 负责“长期资料在哪里、怎么查”，context engine 负责“本次模型调用看到什么”，compaction 负责“历史过长时怎样保留语义并继续运行”。这三者在 agent turn 中汇合，但所有权不同。

## 8.1 机制总览

```text
Workspace files
  MEMORY.md
  memory/YYYY-MM-DD.md
  DREAMS.md
        |
        v
Active memory plugin slot
  memory-core / qmd / lancedb / other backend
        |
        +--> memory_search / memory_get tools
        +--> index watcher / reindex / embedding provider
        +--> dreaming / short-term recall tracking
        |
        v
Agent turn
  bootstrap files + tools + runtime prompt
        |
        v
Context engine
  ingest -> assemble -> compact -> afterTurn
        |
        v
Model request
  selected context messages + optional systemPromptAddition
```

这个图的关键是：OpenClaw 没有一个不可见的“模型内存”。官网说“模型只记得写到磁盘的东西”，源码也遵守这一点。长期记忆来自 workspace 内的 Markdown 文件；搜索能力来自 active memory plugin；模型上下文来自 bootstrap、session transcript、context engine 组装和工具结果。

## 8.2 文件层：记忆的真实持久化位置

官网 memory overview 定义三类文件：

- `MEMORY.md`：长期、精炼、每个主私聊 session 启动时会被加载。
- `memory/YYYY-MM-DD.md` 和 slugged daily notes：当天/昨天的工作层记录、session 摘要、观察和待沉淀上下文。
- `DREAMS.md`：dreaming 和 grounded backfill 的人工审阅面。

源码入口是 `src/memory/root-memory-files.ts`、`src/plugin-sdk/memory-host-files.ts`、`src/plugin-sdk/memory-host-markdown.ts` 以及 memory-core 插件的工具实现。重要边界是：文件属于 agent workspace，而索引属于 memory backend。文件是真相源，索引只是 retrieval 加速层。

这个设计让 OpenClaw 的记忆具备两个工程优点：

- 可审计：用户可以直接读 `MEMORY.md` 和 `memory/*.md`，而不是只能相信某个向量库。
- 可迁移：即便索引损坏，只要 Markdown 文件还在，就可以重新 index。

## 8.3 memory-core：默认记忆插件如何接入

默认 active memory plugin 是 `memory-core`。插件文件在 `extensions/memory-core/`，对外注册通过 `extensions/memory-core/index.ts`、`extensions/memory-core/api.ts`、`extensions/memory-core/runtime-api.ts` 进入 OpenClaw 插件体系。

最核心的工具入口在 `extensions/memory-core/src/tools.ts`：

- `createMemorySearchTool()` 注册 `memory_search`。
- `createMemoryGetTool()` 注册 `memory_get`。
- 工具运行时通过 `loadMemoryToolRuntime()` 进入 host-side memory runtime。
- `getMemoryManagerContext()` 打开当前 agent 的 memory manager。
- 搜索后会调用 `filterMemorySearchHitsBySessionVisibility()`，避免 session transcript search 泄漏到不该看的会话。
- 搜索结果会经 `decorateCitations()` 加引用，再通过 `jsonResult()` 返回给模型。

也就是说，`memory_search` 不是直接读文件的简单 grep。它会走当前 agent、当前 session key、当前 backend、当前 citations policy、当前 visibility policy，并且可能合并 wiki supplement corpus。

## 8.4 索引层：SQLite、FTS5、vector、hybrid

默认 builtin engine 是 SQLite-based。配置解析在 `src/agents/memory-search.ts`：

- 默认 chunk 大小是 400 tokens，overlap 是 80 tokens。
- 默认 `sources` 是 `["memory"]`，session transcript indexing 是实验性 opt-in。
- 默认 hybrid search 开启，vector/text 权重是 0.7/0.3。
- 默认 `maxResults` 是 6，`minScore` 是 0.35。
- SQLite store path 支持 `{agentId}` token，默认每个 agent 一份索引。
- `extraPaths` 会从 defaults 和 per-agent overrides 合并去重。

真正 retrieval 在 `extensions/memory-core/src/memory/manager-search.ts`、`extensions/memory-core/src/memory/hybrid.ts`、`extensions/memory-core/src/memory/manager.ts` 等文件中。`hybrid.ts` 的流程很直接：

1. 向量检索返回 `vectorScore`。
2. FTS/BM25 检索返回 `textScore`。
3. 用配置权重合并成一个 score。
4. 可选 temporal decay 调整陈旧结果。
5. 可选 MMR 降低重复片段。
6. 按最终 score 排序。

`extensions/memory-core/src/memory/manager-search.ts` 还处理了 sqlite-vec 优先路径和 fallback 路径。能加载 sqlite-vec 时走 in-database KNN；不能加载时退回进程内 cosine similarity。关键词路径使用 FTS5；如果 MATCH 在某些 token 模式失败，会 fallback 到 LIKE 子串检索，并记录警告。

## 8.5 provider 选择与 embedding 配置

官网 memory config 说 embedding provider 可以自动检测。源码上的解析在 `src/agents/memory-search.ts`：

- `provider: "auto"` 时先不绑定 adapter，运行时再根据可用 auth/config 判断。
- 指定 provider 时会通过 `getConfiguredMemoryEmbeddingProvider()` 查直接 adapter。
- 如果 provider 是自定义 `models.providers.<id>`，会读取该 provider 的 `api` owner，再映射到 memory embedding adapter。
- `fallback` 也走同一套 adapter 解析。
- multimodal 开启时会校验 provider 是否支持多模态 embedding，并禁止 fallback。

这解释了一个细节：memory embedding provider 不一定等于聊天模型 provider。用户可以聊天用 Claude/Codex，记忆索引用 OpenAI、Gemini、Ollama、local GGUF、Copilot 或 Bedrock。它们通过 OpenClaw config 和 auth profile/secret resolution 连接，而不是耦合在 agent 主模型上。

## 8.6 memory_search 工具的模型侧语义

`memory_search` 的 description 明确告诉模型：当问题涉及 prior work、decisions、dates、people、preferences、todos 时，这是 mandatory recall step。这个工具描述位于 `extensions/memory-core/src/tools.ts`，不是只存在于文档中。

工具参数支持：

- `query`：自然语言或关键词查询。
- `maxResults`、`minScore`：覆盖默认检索阈值。
- `corpus`：`memory`、`sessions`、`wiki`、`all` 等检索范围。

`corpus=all` 时，memory-core 会把 memory results 和 supplement results 合并；wiki 和 memory 分数尺度不同，所以源码先做 corpus balance，再补齐空位。这一点说明 `memory-wiki` 不是替代 memory-core，而是补充 corpus。

## 8.7 memory_get：为什么需要精确读取

`memory_get` 是 exact excerpt read。它的价值不是“查找”，而是“验证”。`memory_search` 返回片段和引用，模型如果要严谨引用或继续读取上下文，就用 `memory_get` 读取某个 memory 文件的 bounded excerpt。

源码上 `createMemoryGetTool()` 会：

- 对 builtin backend 直接调用 host-side `readAgentMemoryFile()`。
- 对 QMD/backend manager 调用 `memory.manager.readFile()`。
- 支持 `corpus=wiki` 读取 registered supplement。
- 出错时返回结构化 disabled/error，而不是抛给模型一个未格式化异常。

这使记忆工具形成两段式：先召回候选，再精读来源。

## 8.8 Context Engine：模型上下文不是 memory backend

`docs/concepts/context-engine.md` 定义 context engine 的四个生命周期：ingest、assemble、compact、after turn。源码 contract 在 `src/context-engine/types.ts`，registry 在 `src/context-engine/registry.ts`。

`ContextEngine` required methods：

- `ingest(params)`：新消息进入 session 时，engine 可以写入自己的 store。
- `assemble(params)`：模型调用前返回有序 messages、估算 token、可选 system prompt addition。
- `compact(params)`：执行压缩或摘要。
- `info`：声明 id、name、version、是否 ownsCompaction。

optional methods 更关键：

- `bootstrap()`：首次看到 session 时导入历史。
- `ingestBatch()`：按 turn 批量导入。
- `afterTurn()`：turn 结束后持久化、触发后台 compaction 或 index。
- `prepareSubagentSpawn()`：子 agent 启动前准备 fork/共享上下文状态。
- `onSubagentEnded()`：子 agent 清理。
- `maintain()`：请求 runtime 帮忙安全 rewrite transcript entries。

这就是 OpenClaw 把 memory 与 context 分开的核心原因：memory plugin 提供 retrieval，context engine 决定 prompt 组装。一个高级 context engine 可以使用 memory plugin 的数据，也可以完全自己维护 context store。

## 8.9 Context Engine 解析与 fallback

`src/context-engine/registry.ts` 实现了进程级 registry。插件通过 public SDK 注册 context engine；core-owned `legacy` id 不能被第三方覆盖。解析逻辑如下：

1. 读取 `config.plugins.slots.contextEngine`。
2. 未配置则用默认 `legacy`。
3. 查 registry factory。
4. 调用 factory，并传入 config、agentDir、workspaceDir。
5. 校验 contract：必须有 `info`、`ingest()`、`assemble()`、`compact()`。
6. 非默认 engine 解析失败时回落到 default engine；default engine 自身失败则抛错。

这里有一个兼容 wrapper：registry 会包装旧 engine，遇到旧 schema 拒绝 `sessionKey` 或 `prompt` 字段时自动重试去掉 legacy compat 字段。它不是业务 fallback，而是插件 API 演进期的参数兼容层。

## 8.10 legacy engine 的含义

默认 `legacy` engine 不是“没有上下文引擎”。它表示沿用 OpenClaw 原始 pipeline：

- ingest no-op，session manager 仍持久化 transcript。
- assemble pass-through，让 agent runtime 的 sanitize、validate、limit pipeline 处理 context。
- compact 委托 built-in summarization compaction。
- afterTurn no-op。

所以当用户没有配置 context engine plugin 时，OpenClaw 仍然有完整上下文行为，只是没有外部插件接管 assembly/compaction。

## 8.11 Compaction：何时发生

compaction 公开行为见 `docs/concepts/compaction.md`。源码核心在：

- `src/agents/compaction.ts`
- `src/agents/pi-embedded-runner/run/preemptive-compaction.ts`
- `src/agents/pi-embedded-runner/compaction-runtime-context.ts`
- `src/agents/pi-embedded-runner/compaction-successor-transcript.ts`
- `src/agents/pi-embedded-runner/post-compaction-loop-guard.ts`
- `src/plugins/compaction-provider.ts`

触发来源有三类：

- preemptive：运行前估算 prompt 可能超过 context window。
- provider overflow：模型返回 context overflow 类错误后 compact 并 retry。
- manual：用户执行 `/compact`。

`preemptive-compaction.ts` 会估算 system prompt、session messages、当前 prompt 的 token，并和 context budget/reserve 比较。它还估算 tool result 可压缩空间，决定 route：

- `fits`
- `truncate_tool_results_only`
- `compact_only`
- `compact_then_truncate`

这比简单“快满了就摘要”更细。大 tool output 有时不需要摘要整段历史，先截断 tool result 就够。

## 8.12 Compaction 如何摘要

`src/agents/compaction.ts` 使用 Pi coding agent 的 `generateSummary()` 做摘要，但 OpenClaw 外面包了一层安全和质量控制：

- `estimateMessagesTokens()` 会剥离 `toolResult.details` 和 runtime-context custom messages，避免敏感 details 进入摘要 prompt。
- `splitMessagesByTokenShare()` 会按 token 拆分，但保持 assistant tool call 和对应 `toolResult` 配对，不在工具块中间切断。
- `summarizeWithFallback()` 对 oversized message 有 fallback，避免单条巨大消息拖垮摘要。
- `summarizeInStages()` 可先生成 partial summaries，再合并。
- identifier preservation 默认 strict，保留 UUID、hash、URL、文件名等 opaque identifiers。

这个实现解释了官网提到的“split point 不会落在 tool block 中间”。源码确实跟踪 pending tool call ids，并在安全边界拆分。

## 8.13 Memory flush 与 compaction 的关系

官网强调 compaction 前会运行 silent memory flush。源码入口在 `src/auto-reply/reply/memory-flush.ts`、`extensions/memory-core/src/flush-plan.ts` 以及 compaction runtime path。

它解决的问题是：compaction 会把旧对话变成摘要，摘要可能丢掉细节；如果对话里出现了 durable facts、preferences、decisions、follow-ups，应该先写入 memory 文件。memory flush 是一次 housekeeping turn，提醒 agent 保存重要信息到文件，再执行摘要。

配置上 `agents.defaults.compaction.memoryFlush.model` 可以指定独立模型。这个 override 是 exact，不继承 active session fallback chain。工程意义是：用户可以聊天用昂贵模型，但 memory flush 用本地小模型；也可以反过来，关键记忆沉淀用更可靠模型。

## 8.14 Dreaming：从召回信号到长期记忆

Dreaming 是 memory-core 的可选后台整理机制。源码集中在：

- `extensions/memory-core/src/dreaming.ts`
- `extensions/memory-core/src/dreaming-phases.ts`
- `extensions/memory-core/src/dreaming-narrative.ts`
- `extensions/memory-core/src/short-term-promotion.ts`
- `extensions/memory-core/src/rem-harness.ts`
- `src/memory-host-sdk/dreaming.ts`

`memory_search` 每次召回后会调用 `recordShortTermRecalls()`，把 query 和命中片段作为 short-term recall tracking。Dreaming 后续可以基于 recall frequency、query diversity、score threshold 等信号，判断哪些候选值得提升到 `MEMORY.md`。

这套机制的关键不是“自动把所有东西写进长期记忆”，而是“先记录机器可排序信号，再由 deep promotion 有门槛地写长期记忆”。`DREAMS.md` 是人工审阅面，`memory/.dreams/` 是机器状态面。

## 8.15 Active Memory 与普通 memory 的边界

`docs/reference/memory-config.md` 特别提醒：active memory 的开关不在 `agents.defaults.memorySearch`，而在 `plugins.entries.active-memory`。这说明 active memory 是一个插件级交互特性，不是 memory search backend 的普通配置。

普通 memory search 解决“我现在需要查历史”的工具调用；active memory 更接近“给交互 session 配一个记忆子代理/持续记忆过程”。源码里 `extensions/memory-core/src/tools.ts` 能识别 `:active-memory:` session key，并对 QMD search mode 做 active memory 专用 override。这是两者在工具层发生交集的地方。

## 8.16 接入方式：用户怎么启用和调试

最小接入路径：

1. 在 agent workspace 中维护 `MEMORY.md` 和 `memory/*.md`。
2. 使用默认 `memory-core` plugin slot。
3. 配置或提供 embedding provider；没有 embedding 时仍可 keyword search。
4. 用 `openclaw memory status` 查看 backend/provider/index 状态。
5. 用 `openclaw memory index --force` 重建索引。
6. 在聊天中让 agent 使用 `memory_search`、`memory_get`。

高级接入路径：

- 设置 `agents.defaults.memorySearch.provider` 指定 embedding provider。
- 设置 `extraPaths` 索引额外 Markdown 文件。
- 开启 `experimental.sessionMemory` 让 transcript 进入 search corpus。
- 设置 `memory.backend = "qmd"` 使用 QMD sidecar。
- 安装/启用 `memory-wiki`，让 durable memory 编译成带 claims/evidence 的 wiki vault。
- 安装 context engine plugin 并设置 `plugins.slots.contextEngine`，接管 context assembly/compaction。

## 8.17 安全和隐私要点

记忆机制的主要风险不是“模型有隐藏状态”，而是“磁盘上有明文状态”和“检索工具会把历史重新带入模型”。

源码缓解点：

- session transcript search 是 opt-in。
- session hits 会经过 visibility filter。
- memory tool 返回 disabled/error，而不是把 backend 异常泄漏成不可控文本。
- compaction 摘要前剥离 `toolResult.details` 和 runtime-context custom messages。
- citations policy 可以控制对模型/回复展示的来源引用。

仍需注意：

- workspace 文件本身就是信任边界，能读 workspace 的进程就能读 memory。
- plugin 是进程内代码，恶意 memory plugin 可以读写本地文件。
- extraPaths 扩大索引范围时，等于扩大可被模型召回的资料范围。

## 8.18 本章源码入口

- `docs/concepts/memory.md`
- `docs/concepts/memory-search.md`
- `docs/concepts/memory-builtin.md`
- `docs/concepts/context-engine.md`
- `docs/concepts/compaction.md`
- `docs/reference/memory-config.md`
- `src/agents/memory-search.ts`
- `src/context-engine/types.ts`
- `src/context-engine/registry.ts`
- `src/context-engine/legacy.ts`
- `src/agents/compaction.ts`
- `src/agents/pi-embedded-runner/run/preemptive-compaction.ts`
- `extensions/memory-core/src/tools.ts`
- `extensions/memory-core/src/memory/manager-search.ts`
- `extensions/memory-core/src/memory/hybrid.ts`
- `extensions/memory-core/src/dreaming.ts`
