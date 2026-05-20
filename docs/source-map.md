# 第 2 章：源码地图

这一页按目录给出阅读路线。OpenClaw 代码量很大，直接全文搜索某个功能容易被兼容层、测试 helper 和 legacy alias 淹没；更有效的方式是先锁定 ownership boundary。

## 2.1 根入口

| 路径 | 作用 |
| --- | --- |
| `openclaw.mjs` | npm/bin wrapper。检查 Node 版本，处理 compile cache、respawn 和 packaged/source checkout 差异。 |
| `src/entry.ts` | TypeScript CLI 入口。处理 profile/container 参数、compile cache、root help fast path，再懒加载 `src/cli/run-main.ts`。 |
| `package.json` | workspace、exports、scripts、依赖和发布文件边界。Node 要求当前是 `>=22.16.0`。 |

## 2.2 CLI

| 路径 | 作用 |
| --- | --- |
| `src/cli/run-main.ts` | 主 CLI 组装入口，基于 commander 注册 root commands。 |
| `src/cli/program/` | command tree、lazy command、help、preaction、消息子命令等。 |
| `src/cli/gateway-cli*` | `openclaw gateway` 命令族。 |
| `src/cli/plugins-cli.ts` | plugin install/list/inspect/enable/disable 等命令入口。 |
| `src/cli/security-cli.ts` | `openclaw security audit` 等安全命令入口。 |

CLI 的架构重点是 lazy registration：先注册 command descriptor，让 help/parse 快；真正重 runtime 到 action 时再加载。这与插件 CLI 的两阶段 metadata/runtime 设计一致。

## 2.3 Gateway

| 路径 | 作用 |
| --- | --- |
| `src/gateway/server.ts` | Gateway 薄入口，懒加载 `server.impl.ts`。 |
| `src/gateway/server.impl.ts` | Gateway 主启动实现，配置、auth、HTTP/WS、method registry、插件、sidecar、reload 都在这里汇聚。 |
| `src/gateway/server-startup-plugins.ts` | Gateway 启动前的插件 bootstrap 编排。 |
| `src/gateway/server-plugin-bootstrap.ts` | 加载 Gateway startup plugins。 |
| `src/gateway/methods/registry.ts` | Gateway RPC method descriptor、scope 和 handler registry。 |
| `src/gateway/server-methods-list.ts` | advertised methods 和 Gateway events 列表。 |
| `src/gateway/auth.ts` | Gateway auth modes、Tailscale/trusted-proxy/shared secret/device token 等授权检查。 |
| `src/gateway/origin-check.ts` | browser/Control UI origin 策略。 |

## 2.4 Agent runtime

| 路径 | 作用 |
| --- | --- |
| `src/agents/pi-embedded-runner.ts` | 对外导出 embedded runner API。 |
| `src/agents/pi-embedded-runner/run.ts` | `runEmbeddedPiAgent()` 主执行管线。 |
| `src/agents/runtime-plan/` | 构建 agent runtime plan 和 auth plan。 |
| `src/agents/pi-embedded-runner/run/` | attempt backend、setup、payload、failover、retry、helpers 等拆分模块。 |
| `src/agents/pi-tools*.ts` | Pi tool 定义、schema、策略、工具调用适配。 |
| `src/agents/tool-policy*.ts` | allow/deny/profile/sender/group/provider 等工具策略。 |
| `src/agents/sandbox/` | sandbox config、Docker/SSH/OpenShell backend、fs bridge、tool policy。 |
| `src/agents/subagent-*` | subagent spawn、registry、announce、lifecycle、recovery。 |

## 2.5 插件

| 路径 | 作用 |
| --- | --- |
| `src/plugins/types.ts` | `OpenClawPluginApi` 和 capability 类型主定义。 |
| `src/plugins/loader.ts` | 插件发现、enablement、配置校验、模块加载、注册、active registry。 |
| `src/plugins/discovery.ts` | plugin candidate discovery。 |
| `src/plugins/manifest*.ts` | manifest 类型、解析、registry、metadata scan。 |
| `src/plugins/plugin-metadata-snapshot.ts` | metadata-only snapshot，避免反复扫描和重 runtime import。 |
| `src/plugins/activation-planner.ts` | 根据 provider/channel/command/route/capability 规划需要加载的插件。 |
| `src/plugins/registry.ts` | 插件注册结果的内存模型。 |
| `src/plugins/runtime/` | 插件 runtime helper 和 capability runtime。 |
| `src/plugin-sdk/` | 对插件作者公开的 SDK subpaths。 |

## 2.6 通道

| 路径 | 作用 |
| --- | --- |
| `src/channels/plugins/types.plugin.ts` | `ChannelPlugin` 完整 capability contract。 |
| `src/channels/plugins/types.core.ts` | 通道核心类型。 |
| `src/channels/plugins/types.adapters.ts` | setup、security、outbound、gateway、directory 等 adapter 类型。 |
| `src/channels/allow-from.ts` | allowlist 相关处理。 |
| `src/channels/command-gating.ts` | 文本命令/控制命令 gating。 |
| `src/channels/session*.ts` | channel inbound 到 session 的 envelope/meta。 |
| `src/infra/outbound/` | outbound delivery、message plan、target resolution、delivery queue。 |
| `extensions/<channel>/` | 具体通道插件，例如 Telegram、Slack、Discord、WhatsApp、Matrix。 |

## 2.7 配置、状态和安全

| 路径 | 作用 |
| --- | --- |
| `src/config/types.openclaw.ts` | `OpenClawConfig` 顶层 schema 类型。 |
| `src/config/io.ts` | 配置读取、include/env、validation、atomic write、audit、runtime snapshot。 |
| `src/secrets/runtime.ts` | SecretRef runtime snapshot 和 auth profile secret resolution。 |
| `src/security/audit.ts` | security audit 主编排。 |
| `src/security/dm-policy-shared.ts` | DM/group allow/pairing/block 决策兼容层。 |
| `src/infra/net/ssrf.ts` | SSRF host/IP/DNS/pinning policy。 |
| `src/infra/net/fetch-guard.ts` | guarded fetch redirect/proxy/dispatcher 策略。 |
| `src/gateway/session-store-key.ts` | session key canonicalization。 |
| `src/gateway/session-transcript-files.fs.ts` | transcript 查找、归档、更新事件。 |

## 2.8 UI 与 apps

| 路径 | 作用 |
| --- | --- |
| `ui/` | Control UI 前端。需遵守 `ui/AGENTS.md`。 |
| `apps/` | 平台应用相关代码。 |
| `packages/sdk/` | 对外 SDK 包。 |

## 2.9 阅读建议

先读 `docs/concepts/architecture.md`、`docs/concepts/agent.md`、`docs/plugins/architecture.md` 和 `docs/gateway/security/index.md`，再读源码入口。遇到具体通道时，先读 `src/channels/plugins/types.plugin.ts`，再进 `extensions/<id>/`，否则会误以为某个通道插件的实现细节是 core 规则。
