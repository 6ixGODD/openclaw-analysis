# 第 6 章：安全分析

OpenClaw 的安全模型必须先按产品定位理解：它是个人 assistant Gateway，不是敌对多租户平台。`docs/gateway/security/index.md` 明确要求一套 Gateway 对应一个 trusted operator boundary；如果存在互不信任用户，应拆成独立 Gateway、凭据、OS 用户或主机。

## 6.1 信任边界

| 边界 | 真实含义 | 常见误读 |
| --- | --- | --- |
| Gateway auth | 认证控制平面调用者 | 不是每个 session 的细粒度租户授权 |
| `sessionKey` | 路由和上下文选择 | 不是 auth token |
| channel allowlist/pairing | 谁能触发 agent | 不能阻止已允许用户诱导工具行为 |
| tool policy | 模型可见/可调用工具边界 | 不是进程隔离 |
| sandbox | 工具执行隔离 | 不包 Gateway 和插件 runtime |
| plugin allowlist | 限制加载哪些 plugin id | 不证明代码来源天然可信 |
| SecretRef/runtime snapshot | 减少明文散落和统一解析 | 不是硬件密钥隔离 |

## 6.2 Gateway auth

源码入口：

- `src/gateway/auth.ts`
- `src/gateway/auth-resolve.ts`
- `src/gateway/auth-rate-limit.ts`
- `src/gateway/origin-check.ts`
- `src/gateway/method-scopes.ts`

`authorizeGatewayConnect()` 支持 shared secret、Tailscale、trusted-proxy、device-token、bootstrap-token 等路径。`assertGatewayAuthConfigured()` 会拒绝配置不完整的 token/password/trusted-proxy mode。

Tailscale 不是只信 header：`auth.ts` 会验证 loopback proxy 形态，并通过 whois 比对 login。Browser origin 检查在 `origin-check.ts`，支持 allowlist、private same-origin 和 local-loopback dev fallback。

安全建议：

- 公网或 LAN 暴露时必须启用 auth。
- trusted-proxy 只能放在会剥离/覆盖身份 header 的可信反代后。
- Control UI/browser surface 要同时看 auth 和 origin。

## 6.3 Channel 访问控制

DM/group 决策可从 `src/security/dm-policy-shared.ts` 看到兼容逻辑：

- group 默认走 allowlist 风格策略。
- DM 默认 `pairing`。
- `open` 还要看 `allowFrom` 是否匹配，`"*"` 才是真公开。
- `disabled` 直接 block。

实际通道应通过新版 `openclaw/plugin-sdk/channel-ingress-runtime` 入口实现，但兼容层清楚展示了核心 decision model：`allow`、`block`、`pairing`。

`docs/gateway/security/index.md` 还区分 trigger authorization 和 context visibility。允许谁触发 agent，不等于 quoted text/thread history 一定只包含 allowlisted sender。需要按通道配置 `contextVisibility`。

## 6.4 Session 隔离不是权限隔离

`docs/concepts/session.md` 说明默认 DM 共享 main session，适合单用户。多用户可设 `session.dmScope: "per-channel-peer"`。源码上 `src/gateway/session-store-key.ts` 做 canonicalization，把 raw key 转成 `agent:<id>:<key>` 形式并处理 legacy main alias。

但 session 隔离只隔离上下文和 transcript，不改变工具权限。多个用户能触发同一个 tool-enabled agent 时，本质上共享该 agent 的 delegated authority。

## 6.5 Tool policy 和 exec 风险

`src/agents/tool-policy-pipeline.ts` 展示工具策略是多层叠加，而不是一个全局开关。策略来源包括 profile、provider profile、global、agent、group、sender。

高风险点：

- `exec`、`process`、`browser`、`nodes`、`gateway`、`cron` 属于高 blast radius 工具。
- `tools.elevated` 会绕过 sandbox。
- interpreter allowlist 容易被 inline eval、loader、wrapper 语义绕开，必须结合 exec approval 和 sandbox。

对应源码：

- `src/agents/bash-tools.exec-approval*.ts`
- `src/infra/exec-approvals*.ts`
- `src/infra/command-analysis/`
- `src/agents/sandbox/tool-policy.ts`

## 6.6 Sandbox 边界

`docs/gateway/sandboxing.md` 明确：

- sandbox 包工具执行。
- Gateway 不在 sandbox 中。
- native plugin 不在 sandbox 中。
- elevated exec 是逃逸路径。
- Docker backend 默认网络为 none。
- Docker bind mount 有 blocked path 检查。

源码入口：

- `src/agents/sandbox.ts`
- `src/agents/sandbox/config.ts`
- `src/agents/sandbox/docker.ts`
- `src/agents/sandbox/ssh.ts`
- `src/agents/sandbox/fs-bridge.ts`

安全结论：sandbox 对 prompt injection 后的工具误用很有价值，但不能把一个 Gateway 变成敌对多租户服务。

## 6.7 SSRF 和网络 fetch

核心实现在：

- `src/infra/net/ssrf.ts`
- `src/infra/net/fetch-guard.ts`
- `src/plugin-sdk/ssrf-policy.ts`
- `src/plugin-sdk/ssrf-runtime.ts`

`ssrf.ts` 处理：

- blocked hostnames，如 `localhost`、`metadata.google.internal`
- 私有/internal/special-use IP
- IPv4/IPv6 特殊地址
- cloud metadata IP
- DNS 解析后复查
- pinned dispatcher
- policy allowlist / private network opt-in

`fetch-guard.ts` 在 fetch 层处理：

- strict/trusted env proxy/trusted explicit proxy 模式
- redirect 次数
- cross-origin unsafe replay
- sensitive headers redirect 保留策略
- timeout 和 dispatcher release

这是 OpenClaw 处理 web_fetch/provider fetch/plugin fetch 的关键防线。

## 6.8 Secrets 和凭据

`src/secrets/runtime.ts` 建立 secrets runtime snapshot。它会：

- clone source config 和 resolved config。
- 收集 candidate agent dirs。
- 读取 auth profile stores。
- 如果没有 SecretRef 复杂解析，走 fast path。
- 否则加载 runtime prepare helpers，收集 config/auth store assignments，解析 SecretRef，再写回 resolved snapshot。

这让 Gateway 和 agent runtime 使用 resolved config，而不是到处临时解析 SecretRef。

公开安全文档列出的凭据位置包括：

- channel credentials under the OpenClaw state directory's `credentials/` tree
- model auth profiles under each agent's `agent/auth-profiles.json`
- optional file-backed secrets payload under the OpenClaw state directory

文档里不应提交这些路径下的真实内容。

## 6.9 Security audit

`src/security/audit.ts` 是 audit 主编排，结合 sync/async/deep/channel/plugin collectors。`docs/gateway/security/index.md` 说明 audit 会检查：

- Gateway bind/auth/Tailscale/trusted proxy
- browser control exposure
- filesystem permissions
- DM/group allowlists
- tool/elevated/sandbox drift
- exec approval drift
- plugins and skills supply chain
- model hygiene

这不是形式化证明，而是运行时配置体检。高风险部署应把 `openclaw security audit --deep` 作为上线前检查。

## 6.10 插件供应链

Native plugin 是 Gateway 进程内代码。`src/plugins/loader.ts` 会校验 manifest config schema、enablement、allow/deny、hardlink policy、source provenance，但无法让不可信代码安全运行。

安全建议：

- 生产只启用明确需要的插件。
- 使用 `plugins.allow`，避免默认开放 workspace plugin。
- 安装来源尽量 pin 版本或 commit。
- 外部 plugin 先读 manifest 和源码，再给 Gateway 加载。

## 6.11 残余风险

OpenClaw 的主要残余风险来自产品本质：

- LLM prompt injection 可能诱导合法工具做危险动作。
- 共享通道中，一个被允许 sender 可以驱动同一 agent 权限集。
- native plugin 不隔离。
- host 上的 Gateway state/config 被改写即视作 trusted operator compromise。
- 浏览器、node、exec、filesystem 工具一旦开放，风险接近真实用户操作权限。

合理的安全目标不是“完全阻止模型被诱导”，而是把谁能触发、能触发什么工具、工具在哪里运行、凭据暴露到哪里控制清楚。

## 6.12 记忆系统的安全拆解

记忆系统有三条风险链：

第一条是文件风险。`MEMORY.md`、`memory/*.md`、session transcripts、dreaming state 都是磁盘文件。它们不是加密 vault，文件系统权限就是基础边界。

第二条是检索风险。`memory_search` 会把历史片段重新注入模型上下文；如果开启 session transcript indexing 或 extraPaths，就扩大了可被召回的资料范围。`extensions/memory-core/src/tools.ts` 里的 session visibility filter 是关键控制点。

第三条是插件风险。memory backend、wiki supplement、context engine 都可以由插件提供。恶意或错误插件可能读过多文件、返回错误引用、注入误导性 prompt addition，或破坏 compaction。

因此安全审计不应只看 Gateway auth，还要看 memory config、extraPaths、sessionMemory、citations policy、active memory plugin、context engine slot 和 enabled plugin 来源。

## 6.13 多 Agent 的安全拆解

多 Agent 的隔离边界容易被高估。它能隔离 session、workspace、memory、agentDir、tools、sandbox config，但它不自动提供：

- 进程隔离。
- 文件系统强隔离。
- 完全独立的 credential fallback。
- hostile tenant isolation。

源码中真正降低风险的点包括：

- `src/routing/resolve-route.ts` 的 deterministic binding priority。
- `src/agents/subagent-target-policy.ts` 的 target allowlist。
- `src/agents/subagent-spawn.ts` 中 sandboxed requester 不能 spawn unsandboxed child 的规则。
- per-agent tools/sandbox/memorySearch config。

审计多 Agent 部署时，应检查默认 agent 是否过强、bindings 是否过宽、群组 sender 是否过多、agent-local auth 是否真的独立、subagent `allowAgents` 是否过宽。
