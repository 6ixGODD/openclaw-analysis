# 第 3 章：Gateway 运行机制

Gateway 是 OpenClaw 的控制平面。它拥有配置快照、认证、RPC method registry、事件广播、消息通道 lifecycle、插件 runtime、session 状态和 HTTP/Control UI surface。

## 3.1 启动入口

`src/gateway/server.ts` 是刻意保持很薄的入口：

- 导出 `startGatewayServer()`。
- 在调用时才动态导入 `src/gateway/server.impl.ts`。
- 通过 `OPENCLAW_GATEWAY_STARTUP_TRACE` 输出 import 阶段耗时。

这说明 Gateway 是重模块，不能在普通 CLI fast path 中被无意导入。`src/entry.ts` 和 CLI lazy command 也在配合这个目标。

## 3.2 `startGatewayServer()` 主流程

`src/gateway/server.impl.ts` 的 `startGatewayServer()` 是实际启动中心。结合代码结构，它的大致流程是：

1. 读取并 materialize 配置：`readConfigFileSnapshot()`、`setRuntimeConfigSnapshot()`。
2. 解析 Gateway auth：`resolveGatewayAuth()`。
3. 准备 secrets runtime snapshot。
4. 准备插件 bootstrap：`prepareGatewayPluginBootstrap()`。
5. 创建 runtime state、live state、readiness checker、health cache。
6. 组装 Gateway method registry。
7. 创建 HTTP server、WebSocket server 和 auxiliary HTTP routes。
8. 监听端口。
9. 启动 post-attach sidecars：channels、cron、plugin services、maintenance。
10. 注册 config write listener，支持运行时 reload。

关键源码：

- `src/gateway/server.impl.ts`
- `src/gateway/server-startup-plugins.ts`
- `src/gateway/server-plugin-bootstrap.ts`
- `src/gateway/server-runtime-state.ts`
- `src/gateway/server-runtime-services.ts`

## 3.3 插件 bootstrap

`prepareGatewayPluginBootstrap()` 在 `src/gateway/server-startup-plugins.ts` 中。它先做 channel startup maintenance 和 session migration，然后初始化 subagent registry，再根据配置和 manifest metadata 构建 plugin lookup table。

核心点：

- `applyPluginAutoEnable()` 会根据配置中引用的 provider/channel/runtime 等自动激活相关插件。
- `loadPluginLookUpTable()` 把 manifest registry、owner maps、startup plugin plan 变成 Gateway 可用的查询表。
- `loadGatewayStartupPluginRuntime()` 最终进入 `server-plugin-bootstrap.ts`，加载启动所需插件。
- minimal test gateway 可以跳过 runtime plugin load。

这对应 `docs/plugins/architecture.md` 中的 control-plane/runtime-plane 分离：启动前尽量用 manifest/metadata 做决策，真正需要运行时行为时再导入插件代码。

## 3.4 Method registry 和 scope

Gateway RPC method 不是随意挂在对象上的函数。`src/gateway/methods/registry.ts` 把每个 method 标准化为 descriptor：

- `name`
- `handler`
- `owner`
- `scope`
- `startup`
- `controlPlaneWrite`
- `advertise`

`createGatewayMethodRegistry()` 会拒绝重复 method 名，并提供 `getHandler()`、`listAdvertisedMethods()`、`getScope()`、`isStartupUnavailable()` 等查询。

来源包括：

- core descriptors：`src/gateway/methods/core-descriptors.ts`
- aux methods：`src/gateway/server-aux-methods.ts`
- plugin gateway methods：`createPluginGatewayMethodDescriptors()`
- channel plugin methods：`src/gateway/server-methods-list.ts`

这让 auth/scope 检查可以面向 descriptor，而不是散落在 handler 内部。

## 3.5 WebSocket 和事件

`docs/concepts/architecture.md` 描述 wire protocol：首帧必须是 `connect`，之后是 `req/res/event`。源码里的 method registry 和 `GATEWAY_EVENTS` 对应这套协议。

`src/gateway/server-methods-list.ts` 列出事件，例如：

- `connect.challenge`
- `agent`
- `chat`
- `session.message`
- `sessions.changed`
- `presence`
- `health`
- `node.pair.requested`
- `device.pair.resolved`
- `exec.approval.requested`
- `plugin.approval.resolved`

这说明 Gateway 不只是 request/response API，还承担长连接状态同步。

## 3.6 认证和 origin 策略

Gateway auth 在 `src/gateway/auth.ts`：

- token/password shared secret
- Tailscale headers + whois verification
- trusted-proxy mode
- device token / bootstrap token
- rate limit scope
- browser origin policy

`assertGatewayAuthConfigured()` 会在 token/password/trusted-proxy 配置不完整时直接失败。`src/gateway/origin-check.ts` 则对 browser origin 做 allowlist、same-origin private host、local loopback 判断。

安全文档 `docs/gateway/security/index.md` 明确：认证到 Gateway 的 operator 是 trusted control-plane role，不是多租户用户隔离。

## 3.7 配置热更新

`src/config/io.ts` 负责读取、校验、写入和 runtime snapshot。Gateway 启动后通过 `registerConfigWriteListener()` 订阅配置写入，再由 `src/gateway/config-reload.ts`、`src/gateway/server-reload-handlers.ts` 等模块决定 reload 范围。

插件和通道 reload 不是“重启整个进程”的唯一方式。通道插件可以声明 `reload.configPrefixes`；Gateway 通过 `plugin-channel-reload-targets.ts` 判断变更是否影响具体 channel/plugin。

## 3.8 HTTP surface

除了 WS，Gateway 还承载：

- Control UI：`src/gateway/control-ui*.ts`
- WebChat：`docs/web/webchat.md` 对应 Gateway WS 使用方式
- MCP HTTP：`src/gateway/mcp-http*.ts`
- OpenAI/OpenResponses compatibility：`src/gateway/openai-http.ts`, `src/gateway/openresponses-http.ts`
- hosted plugin route：`src/plugins/http-registry.ts`, `src/gateway/hosted-plugin-surface-url.ts`

HTTP routes 同样要落到 Gateway auth、origin、scope 和 plugin registry 边界上。

## 3.9 运行时健康和可观测性

Gateway 内置：

- event loop delay monitor：`monitorEventLoopDelay()` in `server.impl.ts`
- health snapshot：`src/gateway/server/health-state.ts`
- readiness checker：`src/gateway/server/readiness.ts`
- startup trace：`OPENCLAW_GATEWAY_STARTUP_TRACE`
- diagnostics timeline：`src/infra/diagnostics-timeline.ts`

这解释了为什么启动路径中大量模块被动态导入：OpenClaw 把启动时间和热路径 import fanout 当成架构问题处理。

## 3.10 Gateway method 的读法

读 Gateway RPC 不要只看 method 名称，要同时看四件事：

- method 在 `src/gateway/server-methods-list.ts` 中是否公开。
- method 在 `src/gateway/methods/registry.ts` 中需要什么 scope。
- handler 是否进入 plugin registry、session store、agent runtime 或 channel runtime。
- 返回结果是否会触发事件广播或 session transcript 更新。

同一个 Gateway method 可能只是读状态，也可能间接启动 agent run、改配置、写 session store、触发 channel delivery。源码里通过 method registry 和 scope 把这些能力归类，是 Gateway 安全面的第一层。

## 3.11 Gateway 与插件 bootstrap 的交界

Gateway 启动并不等于把所有插件 runtime 全量导入。`src/gateway/server-startup-plugins.ts`、`src/plugins/activation-planner.ts`、`src/plugins/plugin-metadata-snapshot.ts` 会尽量先处理 metadata、manifest、enablement 和 activation 计划。

真正 runtime load 通常发生在：

- 启动必须注册 channel/provider/tool/hook 时。
- 某个 Gateway method 需要插件 capability 时。
- agent runtime plan 发现本次 run 需要 provider/tool/channel 时。
- 插件声明 sidecar/service/HTTP route 时。

这种分层让 Gateway 可以更快启动，也让失败面更小：manifest 错误、config 错误、runtime import 错误能被分阶段定位。

## 3.12 Gateway 为什么是多 Agent 的天然中心

多 Agent 不是多个 runtime 随机并行，而是 Gateway 持有统一路由表和 session store。外部消息先进入 Gateway，Gateway 根据 bindings 解析 agent id/session key，再把请求投递到 agent runtime。subagent 也是通过 Gateway `agent` method 启动 child session，而不是在 parent 进程里直接调用函数。

这使 Gateway 能统一处理：

- pairing/auth/origin。
- session lane 和 concurrency。
- session transcript 与 history。
- channel delivery origin。
- subagent registry 和 completion handoff。
- Control UI/SSE/WS 可观测状态。

如果绕过 Gateway 直接跑某个 provider SDK，就会丢掉这些约束。
