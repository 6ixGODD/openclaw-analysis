# 第 7 章：状态与数据流

OpenClaw 的复杂度很大一部分来自状态：配置状态、runtime snapshot、插件 metadata、secrets、session store、transcript、channel credentials、node pairing、tool/process state。读源码时要区分“持久状态”和“运行时派生状态”。

## 7.1 配置状态

顶层类型是 `src/config/types.openclaw.ts` 的 `OpenClawConfig`。它包括：

- `gateway`
- `channels`
- `agents`
- `tools`
- `plugins`
- `models`
- `secrets`
- `session`
- `cron`
- `hooks`
- `memory`
- `mcp`
- `proxy`
- `security`

读写逻辑在 `src/config/io.ts`。重要能力包括：

- JSON5 parse。
- include file 解析和 guard。
- env var substitution。
- plugin-aware validation。
- runtime overrides。
- atomic write。
- config write audit。
- last-known-good recovery。
- runtime snapshot cache 和 write listener。

因此源码中不应随手 `fs.readFile` 读取 config 决策；大多数 runtime 应使用 `getRuntimeConfig()` 或持有的 snapshot。

## 7.2 Runtime config snapshot

Gateway 启动时读取 config，materialize 成 runtime config，并通过 `setRuntimeConfigSnapshot()` 注入。后续 config write 会触发 listener 和 reload 计划。

这里有三个概念：

- source config：用户写的原始配置形状。
- resolved source config：include/env/secret 等解析后配置。
- runtime config：带默认值、插件 auto-enable、runtime override 的实际运行形状。

这个区分避免把运行时默认值写回用户文件，也避免配置变更时无法判断用户真实意图。

## 7.3 Secrets runtime snapshot

`src/secrets/runtime.ts` 管理 secrets snapshot。它会从 config 和 auth profile stores 中收集 SecretRef assignments，然后解析成 resolved config/auth stores。

有 fast path：如果没有需要复杂解析的 SecretRef，直接 clone config 和 auth stores，避免加载重模块。

运行时使用 active secrets snapshot，而不是每次工具/provider 调用都重新解析 secrets。

## 7.4 Plugin metadata snapshot

`src/plugins/plugin-metadata-snapshot.ts` 是 metadata-only 状态，不是 runtime registry。它记录：

- installed plugin index
- manifest registry
- diagnostics
- owner maps
- id normalizer
- manifest records
- watched files/fingerprints

Gateway 用它生成 `PluginLookUpTable`，减少 startup 和 provider/channel discovery 的重复工作。运行时 plugin registry 仍由 `src/plugins/loader.ts` 激活。

## 7.5 Session store 和 transcript

公开文档 `docs/concepts/session.md` 描述持久位置：

- store：OpenClaw state directory 下的 `agents/<agentId>/sessions/sessions.json`
- transcript：OpenClaw state directory 下的 `agents/<agentId>/sessions/<sessionId>.jsonl`

源码入口：

- `src/gateway/session-store-key.ts`
- `src/gateway/session-transcript-files.fs.ts`
- `src/gateway/session-history-state.ts`
- `src/gateway/session-utils.ts`
- `src/sessions/transcript-events.ts`

`session-store-key.ts` 负责把 raw session key canonicalize，处理 `main` alias、legacy default agent、`agent:<id>:<rest>` 格式。`session-transcript-files.fs.ts` 负责查找候选 transcript、归档 reset/deleted transcript，并发出 transcript update event。

## 7.6 Session lifecycle

根据 `docs/concepts/session.md`：

- daily reset 默认按 session start 时间。
- idle reset 按真实 user/channel interaction。
- manual reset 通过 `/new` 或 `/reset`。
- cron/webhook/subagent 等会产生不同 session 形态。

这解释了为什么 store 里要区分：

- `sessionStartedAt`
- `lastInteractionAt`
- `updatedAt`

`updatedAt` 不是 daily/idle freshness 的权威来源。

## 7.7 Channel state 和 credentials

通道状态分两类：

- 通道 runtime state：连接、poller、monitor、directory cache、status 等，通常在插件自己的 `extensions/<id>/src/`。
- 凭据和 allowlist：通常在 OpenClaw state directory 的 `credentials/` tree，或 config/env/SecretRef。

`docs/gateway/security/index.md` 给出凭据地图。源码侧通道 contract 在 `src/channels/plugins/types.plugin.ts`，其中 `secrets`、`auth`、`pairing`、`allowlist`、`security` adapter 是通道拥有自己的状态规则的入口。

## 7.8 Event bus

Gateway 通过 WebSocket events 对客户端广播状态变化。`src/gateway/server-methods-list.ts` 中的 `GATEWAY_EVENTS` 是核心事件列表。

内部也有事件：

- session transcript update：`src/sessions/transcript-events.ts`
- agent events：`src/infra/agent-events.ts`
- diagnostics events：`src/infra/diagnostic-events.ts`
- system events：`src/infra/system-events.ts`

这让 memory index、Control UI、session history SSE、agent progress 和 diagnostics 不需要直接耦合到写文件的位置。

## 7.9 缓存边界

OpenClaw 的缓存设计比较克制：

- plugin metadata snapshot 是显式持有的启动/查询产品。
- plugin module loader cache 是 runtime code load 之后的缓存。
- provider/model catalogs 可以缓存，但必须跟 plugin/config snapshot 兼容。
- prompt cache 需要 deterministic ordering，避免无意义 transcript byte drift。

根规则是：不能用散落的 request-time cache 掩盖缺少 prepared facts 的问题。热路径应该把 provider id、model ref、channel id、capability family、attachment class 等事实向前携带。

## 7.10 数据流示例：一条 Telegram DM

典型路径：

1. Telegram plugin 收到 webhook/polling update。
2. 通道 adapter 解析 sender、chat、thread、message metadata。
3. DM/group 策略决定 allow/block/pairing。
4. Gateway/session 层解析 session key。
5. Agent runtime 排入 session lane。
6. Runtime plan 解析模型、auth、工具、sandbox、plugins。
7. 模型产生 tool calls 和 assistant text。
8. 工具结果写回 transcript。
9. outbound 层按通道能力发送 preview/block/final。
10. session store/transcript/event bus 更新 UI 和后续上下文。

每一步都有明确 ownership：通道拥有平台语义，Gateway 拥有控制面和状态，agent runtime 拥有执行策略，plugin/provider 拥有外部能力。

## 7.11 Memory 数据流

Memory 数据流可以拆成写入、索引、召回、沉淀四段：

1. 写入：agent 或 hook 写 `MEMORY.md`、`memory/YYYY-MM-DD.md`、`DREAMS.md`。
2. 索引：memory-core watcher/CLI/Gateway startup path 发现文件变化，chunk 后写 SQLite/QMD/backend。
3. 召回：模型调用 `memory_search`，backend 返回候选片段，工具层应用 visibility/citations/clamp。
4. 沉淀：dreaming 或人工 review 把高价值短期记录整理进长期文件。

这里的“状态真相源”是 Markdown 文件，而不是向量索引。索引可以重建，文件不应该被当作 cache 随意删除。

## 7.12 Subagent 数据流

Subagent 数据流比普通 agent run 多一层 registry：

1. parent run 调用 spawn tool 或 slash/text command。
2. spawn path 创建 child session key，写 session store patch。
3. 可选 fork parent transcript。
4. 可选 context engine prepare。
5. Gateway `agent` method 启动 child run。
6. subagent registry 记录 runId、owner、requester、origin、cleanup、attachments。
7. child run 完成后，announce/completion path 把结果交还 requester。
8. cleanup/archive/delete 根据 policy 执行。

这些状态散落在 session store、transcript、registry store、thread binding、attachments dir 和 event bus 中。调试 subagent 时不能只看 transcript，还要看 registry 和 session metadata。
