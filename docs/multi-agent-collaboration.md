# 第 9 章：多 Agent 协同与 Subagent 机制

OpenClaw 的多 Agent 不是“多个 Gateway 进程互相聊天”。它是在同一个 Gateway 内，用 agent id、workspace、agentDir、session key、bindings、auth profile 和 tool policy 切出多个运行上下文。Subagent 是其中一个重要执行形态：从当前 run 派生后台 agent run，用独立 session 执行任务，再把结果交还给请求者。

## 9.1 多 Agent 的基本模型

官网 multi-agent 文档把 agent 定义为：

- workspace
- state dir / `agentDir`
- auth profiles
- model registry
- session store
- routing bindings

源码上这些概念散落在几个层：

- agent scope：`src/agents/agent-scope.ts`, `src/agents/agent-scope-config.ts`
- session key：`src/routing/session-key.ts`
- inbound route：`src/routing/resolve-route.ts`
- bindings config：`src/config/bindings.ts`, `src/routing/bindings.ts`
- channel binding API：`src/channels/plugins/binding-*.ts`
- session store target：`src/gateway/server-session-key.ts`, `src/gateway/session-store-key.ts`

默认 agent 是 `main`。当没有配置多 agent 时，session key 仍会归到 `agent:main:<key>` 这类规范化结构，只是用户通常感知不到。

## 9.2 Agent 隔离边界

多 Agent 的隔离主要是逻辑隔离，不是 hostile security boundary：

- workspace 不同：默认 cwd、bootstrap files、memory files 可以不同。
- agentDir 不同：auth profile、状态文件、session store 可以不同。
- session key 不同：并发 lane、transcript、history、routing 状态不同。
- tool config 可不同：`agents.list[].tools` 与 defaults 合并。
- sandbox config 可不同：`agents.list[].sandbox` 覆盖 defaults。

但它不是硬沙箱：

- 如果没有 sandbox，模型工具仍可能通过绝对路径访问 host 文件。
- Gateway 是同一进程。
- plugin runtime 也是同一进程。
- auth profiles 存在 fallback/merge 行为，不是完全密封的 credential vault。

因此多 Agent 是产品和运行时隔离，不是安全多租户隔离。

## 9.3 Agent 配置解析

`resolveAgentConfig(cfg, agentId)` 是常见入口。它把 `agents.defaults` 和 `agents.list[]` 中指定 agent 的覆盖项合并，用于 memory、sandbox、tools、subagents、model 等配置解析。

相关逻辑在：

- `src/agents/agent-scope.ts`
- `src/agents/agent-scope-config.ts`
- `src/agents/memory-search.ts`
- `src/agents/subagent-spawn.ts`
- `src/agents/sandbox.ts`

一个典型流程是：runtime 先从 session key 或 route 解析 agentId，再用 agentId 解析 workspace、agentDir、model/tool/sandbox/memory 配置。这样同一个 Gateway 可以让 Discord A 走 agent `ops`，Telegram B 走 agent `personal`，而两者的 memory 和 auth 使用不同上下文。

## 9.4 Inbound routing：消息如何命中某个 agent

`src/routing/resolve-route.ts` 是多 Agent 消息路由的关键文件。它把 channel/account/peer/guild/team/roles 组合解析成 `ResolvedAgentRoute`：

- `agentId`
- `channel`
- `accountId`
- internal `sessionKey`
- `mainSessionKey`
- `lastRoutePolicy`
- `matchedBy`

匹配优先级和官网一致，源码中是一个 tier 数组：

1. `binding.peer`
2. `binding.peer.parent`
3. `binding.peer.wildcard`
4. `binding.guild+roles`
5. `binding.guild`
6. `binding.team`
7. `binding.account`
8. `binding.channel`
9. default agent

每一层用预先构建的 index 查候选 binding，然后用 `matchesBindingScope()` 做 AND 语义校验。binding 顺序也被保留：同层多个候选时，配置顺序决定先后。

## 9.5 Session key：多 Agent 的持久化主键

session key 是 OpenClaw 运行时里比用户可见 chat id 更底层的 key。它决定：

- transcript 写到哪个 session。
- lane 如何串行化。
- session store 如何记录 model、provider、spawn depth、thread binding 等状态。
- completion handoff 应该交给谁。

`src/routing/session-key.ts` 提供 `buildAgentMainSessionKey()`、`buildAgentPeerSessionKey()`、`parseAgentSessionKey()` 等函数。`resolve-route.ts` 通过 `buildAgentSessionKey()` 构建带 agent id、channel、account、peer scope 的 key。

多 Agent 的一个重要结论是：同一个外部 channel peer，如果 binding 到不同 agent，会得到不同 session key。相反，如果两个入口被配置成同一个 agent 和同一个 dmScope，它们可能折叠到同一主 session。

## 9.6 Auth profiles：共享与隔离的现实边界

官网说明每个 agent 有自己的 auth profiles，并且可以读取 default/main fallback。源码入口包括：

- `src/agents/auth-profiles.ts`
- `src/agents/model-auth.ts`
- `src/agents/runtime-plan/auth.ts`
- `src/agents/agent-scope-config.ts`

工程含义：

- 每个 agent 可以有不同 provider credential、OAuth token 或 model profile。
- agent-local profile 优先。
- 缺少本地 profile 时可能沿用 default/main profile。
- OAuth refresh token 不会简单复制成多个 agent 独立凭据。

所以如果用户要求“强隔离账号”，只配多 Agent 不够，还要单独审视 auth profile fallback 和 provider credential 来源。

## 9.7 Memory 的多 Agent 作用域

记忆默认按 workspace 和 agent id 分开：

- `MEMORY.md` 和 `memory/*.md` 在 agent workspace。
- builtin SQLite store path 带 `{agentId}`。
- QMD extra collections 可以在 `agents.list[].memorySearch.qmd.extraCollections` 中为某个 agent 单独配置。

跨 agent 搜索不是默认透明共享。要让 agent A 搜索 agent B 或共享资料，需要显式配置 extra paths/collections。这符合 OpenClaw 的 owner boundary：跨 agent 资料共享是配置行为，不是隐式泄漏。

## 9.8 Subagent 是什么

Subagent 是从一次 agent run 中派生的后台 agent run。它有自己的 session key，形如：

```text
agent:<agentId>:subagent:<uuid>
```

源码构造在 `src/agents/subagent-spawn.ts`：

```ts
const childSessionKey = `agent:${targetAgentId}:subagent:${crypto.randomUUID()}`;
```

这意味着 subagent 不是当前 transcript 里的一个工具函数调用结果，而是一个真正的 session。它会进入 Gateway `agent` method，走标准 agent runtime，只是 lane、delivery、cleanup、tool policy 和 completion handoff 有 subagent 专用规则。

## 9.9 Subagent spawn 的源码流程

核心入口是 `spawnSubagent()`，位于 `src/agents/subagent-spawn.ts`。流程可拆为十步：

1. 读取 runtime config。
2. 解析 requester internal session key。
3. 检查当前 spawn depth 和 max children。
4. 解析 requester agent id 与 target agent id。
5. 检查 `allowAgents`、`requireAgentId` 等 target policy。
6. 解析 sandbox 状态，禁止 sandboxed requester spawn unsandboxed child。
7. 创建 child session key 并写入初始 session store patch。
8. 准备 context：`isolated` 或 `fork`。
9. 让 active context engine 执行 `prepareSubagentSpawn()`。
10. 调 Gateway `agent` method 启动 child run，并注册到 subagent registry。

涉及文件：

- `src/agents/subagent-spawn.ts`
- `src/agents/subagent-spawn.runtime.ts`
- `src/agents/subagent-target-policy.ts`
- `src/agents/subagent-capabilities.ts`
- `src/agents/subagent-depth.ts`
- `src/agents/subagent-registry.ts`

## 9.10 context: isolated 与 fork

Subagent 有两个 context mode：

- `isolated`：默认，child 从任务说明和自己的 bootstrap 开始，不继承 parent transcript。
- `fork`：把 parent transcript fork 成 child 的起点，让 child 带着当前上下文继续工作。

源码中的限制很明确：

- `context="fork"` 当前要求 target agent 与 requester agent 相同。
- parent session 必须有可用 transcript。
- fork 失败时可能根据策略降级到 isolated，并把 fallback note 返回给 requester。

实现入口是 `prepareSubagentSessionContext()`。它通过 `resolveGatewaySessionStoreTarget()` 找 parent/child store，再调用 `resolveParentForkDecision()` 和 `forkSessionFromParent()`。fork 成功后，child session store 会写入 `sessionId`、`sessionFile`、`forkedFromParent`。

## 9.11 Context engine 与 subagent 生命周期

在 child session 准备好但还没真正启动 agent run 前，`spawnSubagent()` 会调用：

```ts
engine.prepareSubagentSpawn?.({
  parentSessionKey,
  childSessionKey,
  contextMode,
  parentSessionId,
  parentSessionFile,
  childSessionId,
  childSessionFile,
  ttlMs,
})
```

如果 context engine 返回 rollback handle，而后续 spawn 失败，OpenClaw 会 best-effort rollback。这个 hook 是 plugin context engine 支持 subagent 的关键接入点：它可以为 child session 复制 retrieval state、建立上下文 lineage、记录 parent-child 映射或设置 TTL。

child 结束时，context engine 还可以通过 `onSubagentEnded()` 清理状态。相关类型在 `src/context-engine/types.ts`。

## 9.12 Subagent registry：后台任务如何被追踪

child run 启动后会调用 `registerSubagentRun()`，记录：

- runId
- childSessionKey
- controllerSessionKey
- requesterSessionKey
- requesterOrigin
- task/taskName/label
- model
- agentDir/workspaceDir
- timeout
- spawnMode
- attachments dir
- completion expectation

registry 相关文件很多，因为它要支持 list、info、kill、steer、completion、cleanup、liveness、orphan recovery：

- `src/agents/subagent-registry.ts`
- `src/agents/subagent-registry.store.ts`
- `src/agents/subagent-registry-runtime.ts`
- `src/agents/subagent-registry-completion.ts`
- `src/agents/subagent-run-liveness.ts`
- `src/agents/subagent-orphan-recovery.ts`
- `src/agents/subagent-session-cleanup.ts`

这解释了为什么 subagent 不是普通 fire-and-forget Promise。OpenClaw 需要在 Gateway 重启、通道断线、requester active/inactive、thread binding、cleanup policy 等情况下仍能管理它。

## 9.13 Completion handoff：为什么 child 不直接乱发消息

官网 subagents 文档强调 child completion 不是 raw-send 到 chat。源码中 child run 通常用 `deliver:false` 或受 thread binding 控制，然后 completion 通过 registry/announce path 交还给 requester。

相关文件：

- `src/agents/subagent-announce.ts`
- `src/agents/subagent-announce-delivery.ts`
- `src/agents/subagent-announce-dispatch.ts`
- `src/gateway/session-subagent-reactivation.ts`
- `src/agents/subagent-yield-output.ts`

设计原因：

- requester session 可能仍在运行，需要 wake/steer 而不是插入混乱消息。
- child 结果要带 metadata：source、session ids、status、stats、follow-up。
- channel delivery 需要遵守原始 requesterOrigin、thread binding、account/channel policy。
- child 不应该绕过 parent/controller 的权限边界。

这就是 `sessions_yield` 存在的原因：parent 可以结束当前 turn，让 runtime 等待后台事件，而不是模型自己轮询。

## 9.14 Tool policy：子 agent 为什么默认没有所有工具

Subagent 的工具权限经过两层：

1. 常规 tool policy pipeline：profile、provider、global、agent、group、sender 等。
2. subagent restriction layer：按 spawn depth、role、control scope 限制 session/system tools。

源码入口包括：

- `src/agents/subagent-capabilities.ts`
- `src/agents/subagent-system-prompt.ts`
- `src/agents/tools/subagents-tool.ts`
- `src/agents/tool-policy-pipeline.ts`

默认 `maxSpawnDepth` 是 1。深度 1 的普通 worker 不默认拥有 session 管理工具；当配置允许 depth 2 的 orchestrator pattern 时，orchestrator 才可能获得管理 child 的能力。这防止一个模型任务无限制造后台任务，也防止普通 worker 越权操作 requester session。

## 9.15 Sandbox 继承与拒绝规则

`spawnSubagent()` 会解析 requester 和 child runtime 的 sandbox 状态：

- 如果 requester sandboxed，而 child unsandboxed，拒绝。
- 如果用户显式 `sandbox="require"`，但 target runtime 不 sandboxed，拒绝。
- 否则按 `inherit` 或配置继续。

这条规则很重要：sandboxed parent 不能通过 spawn 一个 unsandboxed child 来逃逸。源码判断在 `src/agents/subagent-spawn.ts`，sandbox 状态来自 `resolveSandboxRuntimeStatus()`。

## 9.16 Thread-bound subagent 与 channel 接入

Subagent 支持 thread-bound persistent session，尤其用于 Discord 这类有线程概念的 channel。相关代码包括：

- `src/channels/thread-bindings-policy.ts`
- `src/shared/thread-binding-lifecycle.ts`
- `src/channels/plugins/thread-binding-api.ts`
- `src/auto-reply/reply/commands-subagents/action-focus.ts`
- `src/auto-reply/reply/commands-subagents/action-unfocus.ts`

当 `thread=true` 或 slash/text command 要求 thread binding 时，spawn path 会：

- 解析 channel policy 的 default spawn context。
- 创建或确认 thread binding。
- 把 child session 与 thread delivery origin 绑定。
- 在 persistent session 模式下直接把初始 child run deliver 到绑定 thread，或保持 completion announce path。

用户侧命令 `/focus`、`/unfocus`、`/agents`、`/subagents spawn/list/kill/log/info/send/steer` 最终都落到这套 binding 和 registry。

## 9.17 Agent-to-agent 协同的三种形态

OpenClaw 里“多 Agent 协同”可以分三层：

第一层是路由协同：不同外部会话进入不同 agent。例子：家庭 Telegram 群进 `home` agent，公司 Discord 频道进 `work` agent。

第二层是手动/工具派生：当前 agent 用 `sessions_spawn` 把子任务交给另一个允许的 agent。例子：主 agent 让 `research` agent 查资料，让 `coder` agent 做实现。

第三层是 orchestrator pattern：允许一层 orchestrator 再派生 worker。这个需要提高 `maxSpawnDepth`，并接受更复杂的权限和 completion chain。

源码最支持的是第二层和受控第三层。它不是一个无边界 swarm，而是带 session ownership、target allowlist、depth、children count、tool policy、completion routing 的受控协作系统。

## 9.18 接入方式：如何配置多 Agent

最小接入：

1. 在 config 中添加 `agents.list[]`，设置 id、workspace、model/tools/sandbox 等。
2. 使用 `openclaw agents add <id>` 或配置文件维护 agent。
3. 通过 bindings 把 channel/account/peer/guild/team/roles 指向 agent。
4. 用 `openclaw agents list --bindings` 检查路由。

Subagent 接入：

1. 确保当前 agent 的 tool profile 暴露 `sessions_spawn` 或相关 subagent tool。
2. 配置 `agents.defaults.subagents` 或 per-agent `subagents`。
3. 设置 `allowAgents` 控制可派生目标。
4. 需要跨 agent 时显式传 `agentId`。
5. 需要 parent transcript 时用 `context:"fork"`，但目前仅同 agent。
6. 需要 persistent thread 时使用 thread-bound commands 或 `thread:true`。

关键配置项：

- `agents.defaults.subagents.maxSpawnDepth`
- `agents.defaults.subagents.maxChildrenPerAgent`
- `agents.defaults.subagents.maxConcurrent`
- `agents.defaults.subagents.requireAgentId`
- `agents.list[].subagents.allowAgents`
- `agents.list[].sandbox`
- `agents.list[].tools`

## 9.19 失败模式与审计重点

多 Agent/subagent 最值得审计的失败模式：

- binding 太宽，导致群聊消息进入高权限 agent。
- default/main auth fallback 让本应隔离的 agent 复用凭据。
- sandboxed requester 能否通过某条路径启动 unsandboxed runtime。源码已有拒绝规则，但新增 runtime path 要继续守住。
- thread binding cleanup 失败，导致旧 thread 仍关联 child session。
- orphan recovery/tombstone 处理不当，导致完成结果重复 announce。
- `context="fork"` 泄漏 parent transcript 给不该看的 target agent。当前源码限制同 agent，是合理约束。
- session transcript search 开启后，visibility filter 是否覆盖所有 corpus 返回路径。

## 9.20 本章源码入口

- `docs/concepts/multi-agent.md`
- `docs/tools/subagents.md`
- `src/routing/resolve-route.ts`
- `src/routing/session-key.ts`
- `src/agents/agent-scope.ts`
- `src/agents/agent-scope-config.ts`
- `src/agents/subagent-spawn.ts`
- `src/agents/subagent-spawn.runtime.ts`
- `src/agents/subagent-target-policy.ts`
- `src/agents/subagent-capabilities.ts`
- `src/agents/subagent-registry.ts`
- `src/agents/subagent-announce.ts`
- `src/channels/thread-bindings-policy.ts`
- `src/auto-reply/reply/commands-subagents.ts`
