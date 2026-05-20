# 第 10 章：架构亮点与风险点

这一页从工程角度总结 OpenClaw 源码里值得学习的设计，以及继续深入审计时应优先看的风险面。

## 10.1 亮点一：懒加载作为架构约束

OpenClaw 很多入口都刻意保持薄：

- `src/gateway/server.ts` 懒加载 `server.impl.ts`。
- `src/entry.ts` 对 root help/version 做 fast path。
- CLI commands 用 lazy registration。
- Gateway startup sidecars 可 defer。
- 插件通过 manifest/metadata/public artifacts 尽量避免冷路径导入 runtime。

这不是小优化，而是架构纪律。Gateway、插件和 provider SDK 都很重；如果导入边界失控，CLI 响应、测试速度、Gateway 启动和内存都会退化。

## 10.2 亮点二：manifest/control plane 与 runtime plane 分离

插件系统最好的设计点是先做 metadata/control-plane 决策，再加载 runtime code：

- `src/plugins/plugin-metadata-snapshot.ts`
- `src/plugins/plugin-lookup-table.ts`
- `src/plugins/activation-planner.ts`
- `src/plugins/loader.ts`

这让 OpenClaw 可以解释“为什么某插件会加载/不加载”、提前校验配置、减少 startup fanout，并保持 plugin ownership 清晰。

## 10.3 亮点三：capability contract 而不是 vendor hardcode

`docs/plugins/architecture.md` 的核心是 plugin owns vendor/feature，core owns capability contract。源码上由 `OpenClawPluginApi` 和 `src/plugin-sdk/` 体现。

好处：

- 新 provider 不需要改 agent 主循环。
- 新 channel 不需要 core 写专用工具。
- shared policy 可以集中在 core capability layer。
- vendor API 差异留在 owner plugin。

这对多 provider、多 channel 的项目非常关键。

## 10.4 亮点四：工具策略是 pipeline

`src/agents/tool-policy-pipeline.ts` 把工具可见性拆成 profile、provider、global、agent、group、sender 多层策略。这个模型适合消息通道场景，因为“谁说的”“在哪个群”“哪个 agent”“哪个 provider”都会影响工具风险。

相比一个全局 allowlist，这种 pipeline 更能表达真实权限。

## 10.5 亮点五：安全文档和源码模型基本一致

`docs/gateway/security/index.md` 没有过度承诺。它明确：

- personal assistant trust model。
- 不是 hostile multi-tenant boundary。
- sessionKey 不是 auth。
- plugin 是进程内代码。
- sandbox 不包 Gateway。

源码中的 auth、origin、dm policy、sandbox、SSRF、audit 也和这些声明对齐。这个一致性本身是安全成熟度的一部分。

## 10.6 亮点六：session 和 transcript 事件化

`src/gateway/session-transcript-files.fs.ts` 在归档 transcript 时会发 `emitSessionTranscriptUpdate()`。这类细节说明 OpenClaw 把 session 文件变更作为事件源，供 memory、history、UI 等消费，而不是让每个消费者轮询磁盘。

## 10.7 主要风险点

### Native plugin 风险

Native plugin in-process 执行。allowlist、manifest、schema 都不能把恶意代码变安全。继续审计应重点看：

- plugin install source 校验：`src/plugins/install*.ts`
- hardlink/symlink/path policy：`src/plugins/hardlink-policy.ts`, `src/plugins/path-safety.ts`
- public-surface loader：`src/plugins/public-surface-loader.ts`
- plugin HTTP route registry：`src/plugins/http-registry.ts`

### Tool policy 与 elevated 组合

高风险组合是开放 channel + broad tools + elevated exec。重点看：

- `src/agents/tool-policy*.ts`
- `src/agents/bash-tools.exec*.ts`
- `src/infra/exec-approvals*.ts`
- `src/infra/command-analysis/`
- `src/agents/sandbox/tool-policy.ts`

审计时不要只看某个 tool 是否存在，要看该请求上下文下它是否经过 pipeline 后可见。

### Gateway auth/trusted-proxy/Tailscale

重点看：

- `src/gateway/auth.ts`
- `src/gateway/auth-resolve.ts`
- `src/gateway/origin-check.ts`
- `src/gateway/startup-control-ui-origins.ts`
- `src/security/audit-gateway-config.ts`

trusted-proxy 和 Tailscale header 相关代码要特别关注 header spoof、proxy allowlist、loopback 判断和 origin fallback。

### SSRF 与 proxy 模式

重点看：

- `src/infra/net/ssrf.ts`
- `src/infra/net/fetch-guard.ts`
- `src/infra/net/proxy-env.ts`
- `src/plugin-sdk/ssrf-policy.ts`

复杂点是 redirect、proxy、DNS pinning、private network opt-in、fake IP range 和 provider-specific fetch 的组合。

### Session 隐私误用

默认 DM main session 对单用户友好，但多用户场景必须配置 dmScope。重点看：

- `src/gateway/session-store-key.ts`
- `src/channels/session*.ts`
- `src/security/context-visibility.ts`
- `src/security/dm-policy-shared.ts`

审计目标不是证明 sessionKey 可猜，而是证明是否有用户能看到/影响不该共享的上下文或工具权限。

## 10.8 继续深读路线

1. 从 `src/gateway/server.impl.ts` 画启动时序。
2. 从 `src/agents/pi-embedded-runner/run.ts` 画一个 turn 的状态机。
3. 从 `src/plugins/loader.ts` 画插件加载状态机。
4. 从一个具体通道插件，例如 `extensions/telegram/`，对照 `ChannelPlugin` contract。
5. 从 `src/security/audit.ts` 反推 OpenClaw 官方认为高风险的配置组合。

## 10.9 可改进空间

这些不是 bug 结论，而是架构层继续优化方向：

- `runEmbeddedPiAgent()` 仍是超大编排函数，后续可继续把阶段状态机显式化。
- Gateway `server.impl.ts` 聚合面很宽，启动阶段和运行阶段可以进一步拆出更可测试的 planner。
- plugin SDK exports 很多，稳定/实验/内部 subpath 的可见边界需要持续收紧。
- security audit 很强，但 operator-facing threat profiles 可以更结构化，例如 personal、team trusted、public bot、sandboxed lab。
- 通道插件数量大，contract tests 对 shared `message` action、contextVisibility、pairing 和 streaming 的一致性仍是长期重点。
