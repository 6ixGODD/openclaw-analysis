# 第 4 章：Agent 运行机制

OpenClaw 的 agent runtime 是 Gateway 内部的执行引擎。它把一个 inbound message 或 CLI `openclaw agent` 调用变成 session-bound 的模型调用、工具调用、流式事件和最终回复。

## 4.1 入口和分层

对外入口是 `src/agents/pi-embedded-runner.ts`，它导出 `runEmbeddedPiAgent()` 等 API。真实实现位于 `src/agents/pi-embedded-runner/run.ts`。

`runEmbeddedPiAgent()` 的职责很重，但拆分清楚：

- lane 和 queue：`src/agents/pi-embedded-runner/lanes.ts`
- backend attempt：`src/agents/pi-embedded-runner/run/backend.ts`
- setup/model/hooks：`src/agents/pi-embedded-runner/run/setup.ts`
- payload：`src/agents/pi-embedded-runner/run/payloads.ts`
- failover：`src/agents/pi-embedded-runner/run/failover-policy.ts`
- retry：`src/agents/pi-embedded-runner/run/retry-limit.ts`
- compaction：`src/agents/pi-embedded-runner/compact.queued.ts`

## 4.2 Session 和 lane

`runEmbeddedPiAgent()` 开头会尝试回填 `sessionKey`。如果调用方只给 `sessionId`，它会通过 `resolveStoredSessionKeyForSessionId()` 或 `resolveSessionKeyForRequest()` 找回路由 key。

随后它创建两个队列层：

- session lane：同一 session 的 turn 串行化。
- global lane：限制全局并发和资源竞争。

这比“每条消息直接开跑一个模型请求”更稳：通道消息、CLI 请求、cron、heartbeat、subagent 都可以进入同一套 lane 规则。

相关源码：

- `src/agents/pi-embedded-runner/run.ts`
- `src/process/command-queue.ts`
- `src/gateway/session-store-key.ts`

## 4.3 Workspace 和 bootstrap

`docs/concepts/agent.md` 说明 workspace 是 agent 的 cwd 和 prompt context 来源。源码中 `resolveRunWorkspaceDir()`、`resolveAgentWorkspaceDir()`、`resolveAgentDir()` 决定本次 run 的 workspace/agent dir。

OpenClaw 会把这些文件注入系统 prompt：

- `AGENTS.md`
- `SOUL.md`
- `TOOLS.md`
- `BOOTSTRAP.md`
- `IDENTITY.md`
- `USER.md`

相关实现分散在：

- `src/agents/bootstrap-files.ts`
- `src/agents/bootstrap-prompt.ts`
- `src/agents/system-prompt.ts`
- `src/agents/workspace*.ts`

## 4.4 Runtime plan

`src/agents/runtime-plan/build.ts` 和 `src/agents/runtime-plan/auth.ts` 负责在单次 run 前准备“本次要用什么能力”：

- agent id 和 execution contract
- model/provider/runtime
- auth profile order
- tools
- sandbox context
- plugin runtime dependencies

`runEmbeddedPiAgent()` 中会调用 `ensureRuntimePluginsLoaded()`，保证被本次模型/工具/通道需要的插件已经在 runtime registry 中。

## 4.5 模型选择和 auth

模型选择不是简单取 `agents.defaults.model`。相关代码包括：

- `src/agents/model-selection*.ts`
- `src/agents/model-ref-shared.ts`
- `src/agents/model-auth.ts`
- `src/agents/auth-profiles.ts`
- `src/plugins/provider-runtime.ts`

OpenClaw 支持 provider/model ref、alias、auth profile fallback、profile cooldown、runtime auth refresh、provider hook 介入和 failover。`runEmbeddedPiAgent()` 会记录 auth success/failure，并根据错误类型选择是否轮换 profile 或 fallback model。

## 4.6 Turn 状态机

把 `runEmbeddedPiAgent()` 简化成状态机，可以这样读：

1. `normalize request`：解析输入、session、channel、delivery context、idempotency key。
2. `queue`：进入 session lane/global lane，避免同一 session 并发破坏 transcript。
3. `prepare runtime`：解析 workspace、agentDir、runtime plan、auth plan、plugin runtime。
4. `build prompt/tools`：加载 bootstrap/context、注册工具、应用 tool policy、建立 sandbox/elevated routing。
5. `attempt model call`：执行 backend attempt，处理 stream、tool calls、tool results。
6. `recover`：遇到 context overflow、quota、auth failure、empty response、reasoning-only、tool result 过大等情况时 retry/failover/compact。
7. `persist and deliver`：写 session transcript，广播事件，返回 reply payload 或 channel delivery。

这个状态机解释了为什么 agent runtime 文件很多。它不是一段线性 provider call，而是一个可恢复的执行系统。

## 4.7 工具策略与模型可见性的关系

模型只能调用“本次 prompt 中暴露出来的工具 schema”。OpenClaw 因此把工具选择放在运行前，而不是工具调用时才临时判断。`src/agents/tool-policy-pipeline.ts` 会把多层策略合并：

- runtime/tool profile
- provider policy
- global defaults
- per-agent policy
- group/channel/sender policy
- inherited subagent allow/deny
- sandbox/elevated constraints

这套策略影响两个面：一是工具是否出现在 model-facing schema 中，二是工具真正执行时是否还要 approval、sandbox 或 elevated path。对于消息通道场景，这比单个 allowlist 更合适，因为同一个 agent 在私聊和群聊里应该拥有不同风险预算。

## 4.8 Runtime 与 context/memory 的交点

agent runtime 不直接“拥有”长期记忆。它在每次 turn 中把这些来源汇合：

- bootstrap files 注入长期身份和工作区说明。
- session transcript 提供当前会话历史。
- memory tools 让模型按需召回文件索引。
- context engine 可以改变本次 messages 的 assembled view。
- compaction 在上下文过长时重写模型可见历史。

因此用户说“OpenClaw 记住了什么”时，需要区分：文件里保存了什么、索引能搜到什么、工具是否暴露给模型、context engine 是否注入了什么、当前 session transcript 是否还在 active context 中。

## 4.9 Subagent 在 agent runtime 中的位置

Subagent spawn 对模型来说是一个 tool/action；对 runtime 来说是另一次完整 `agent` method 调用。child run 会进入自己的 session key 和 lane，拥有自己的 prompt、tools、model、sandbox、workspace 和 transcript。parent 不直接同步等待 child，而是通过 registry、yield、announce/handoff 协调。

这个设计比“在同一个 prompt 里模拟多个角色”更可靠：每个 child 都有可审计 transcript、可中断 runId、可清理 session、可独立配置 target agent。

## 4.10 工具目录和工具策略

工具策略是多层 pipeline。`src/agents/tool-policy-pipeline.ts` 把这些来源依次应用：

- `tools.profile`
- `tools.byProvider.profile`
- `tools.allow`
- `tools.byProvider.allow`
- `agents.<id>.tools.allow`
- `agents.<id>.tools.byProvider.allow`
- group policy
- sender policy

它还会识别 plugin-only allowlist、不可用 core tool 和 plugin group。最终 filtering 由 `src/agents/pi-tools.policy.ts` 执行。

这意味着工具可见性是运行时结果，不是“代码里定义了 tool 就一定暴露给模型”。

## 4.11 Sandbox 和 elevated

`docs/gateway/sandboxing.md` 明确 sandbox 只包工具执行，不包 Gateway。源码层：

- public barrel：`src/agents/sandbox.ts`
- config：`src/agents/sandbox/config.ts`
- context：`src/agents/sandbox/context.ts`
- Docker：`src/agents/sandbox/docker.ts`
- SSH：`src/agents/sandbox/ssh.ts`
- fs bridge：`src/agents/sandbox/fs-bridge.ts`
- tool policy：`src/agents/sandbox/tool-policy.ts`

`tools.elevated` 是显式逃逸路径。安全上不能把 sandbox 看成万能边界；它是降低 tool blast radius 的运行模式。

## 4.12 执行 attempt、retry 和 failover

`runEmbeddedPiAgent()` 的一次模型尝试由 `runEmbeddedAttemptWithBackend()` 执行。周边策略包括：

- 空回复 retry：`DEFAULT_EMPTY_RESPONSE_RETRY_LIMIT`
- reasoning-only retry
- planning-only retry
- context overflow/compaction
- rate limit / overload backoff
- auth profile rotation
- model fallback
- incomplete turn 修复
- tool result truncation

这类逻辑集中在 `src/agents/pi-embedded-runner/run/`，而不是散在 provider 插件里。provider 插件负责 vendor 接入，agent runtime 负责横向执行策略。

## 4.13 Streaming 和 delivery

`docs/concepts/streaming.md` 区分两种 streaming：

- block streaming：把完成的 assistant block 作为普通 channel message 发送。
- preview streaming：在 Telegram/Discord/Slack/Matrix/Mattermost 等可编辑 surface 上更新草稿/预览消息。

agent runner 会产生 agent events、assistant text、tool progress 和 final payload；outbound 层负责按 channel 能力投递。

相关源码：

- `src/agents/pi-embedded-block-chunker.ts`
- `src/agents/stream-message-shared.ts`
- `src/infra/outbound/deliver.ts`
- `src/channels/draft-preview-finalizer.ts`
- `src/plugin-sdk/channel-streaming.ts`

## 4.14 Subagent

Subagent 不是独立产品线，而是同一个 agent runtime 的后台/隔离运行能力：

- spawn：`src/agents/subagent-spawn.ts`, `src/agents/subagent-spawn.runtime.ts`
- registry：`src/agents/subagent-registry*.ts`
- announce：`src/agents/subagent-announce*.ts`
- recovery：`src/agents/subagent-orphan-recovery.ts`

Gateway 启动时调用 `initSubagentRegistry()`，说明 subagent 生命周期属于 Gateway runtime，而不是临时 CLI 状态。
