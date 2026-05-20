# 第 5 章：插件与通道机制

OpenClaw 的扩展性来自插件系统。插件不是“随便 import 的一段代码”，而是 manifest、enablement、activation plan、runtime registry 和 SDK contract 共同约束的能力边界。

## 5.1 插件模型

`docs/plugins/architecture.md` 给出的核心定义是：

- plugin 是 ownership boundary。
- capability 是 core contract。
- native plugin in-process 运行。
- compatible bundle 更多是 metadata/content pack。

源码中的主 contract 是 `src/plugins/types.ts` 的 `OpenClawPluginApi`。它提供注册点：

- `registerProvider`
- `registerChannel`
- `registerTool`
- `registerHook`
- `registerGatewayMethod`
- `registerModelCatalogProvider`
- `registerSpeechProvider`
- `registerMediaUnderstandingProvider`
- `registerImageGenerationProvider`
- `registerVideoGenerationProvider`
- `registerWebSearchProvider`
- `registerWebFetchProvider`
- `registerDetachedTaskRuntime`
- `registerMemoryCapability`

这使 OpenClaw 可以把 provider、channel、tool、hook、service、route 等能力统一纳入 registry。

## 5.2 Manifest-first 设计

插件加载前先读 manifest。相关源码：

- `src/plugins/manifest.ts`
- `src/plugins/manifest-types.ts`
- `src/plugins/manifest-registry.ts`
- `src/plugins/plugin-metadata-snapshot.ts`
- `src/plugins/plugin-lookup-table.ts`

manifest 提供：

- plugin id/name/version/kind
- entry/runtime/setup entry
- providers/channels/commands/hooks/activation hints
- config schema
- default enablement
- public artifacts

这样 Gateway 可以在不执行插件 runtime 的情况下做配置校验、owner lookup、auto-enable、activation plan 和 setup hints。

## 5.3 Loader 管线

`src/plugins/loader.ts` 的 `loadOpenClawPlugins()` 是核心加载函数。它的行为可以拆成：

1. 归一化插件配置：allow/deny/entries/load paths/slots。
2. 构建 discovery context 和 cache key。
3. 发现候选插件：`discoverOpenClawPlugins()`。
4. 加载 manifest registry：`loadPluginManifestRegistry()`。
5. 根据 enablement 和 onlyPluginIds 筛选。
6. 校验 plugin config schema。
7. 解析 entry module 和 SDK alias。
8. 创建 plugin API：`buildPluginApi()`。
9. 执行 plugin `register(api)`。
10. 捕获注册结果到 registry。
11. 激活 active runtime registry。

`mode: "validate"` 会停在校验/记录层，不执行完整 runtime 注册。`onlyPluginIds` 支持按 activation plan 缩窄加载范围。

## 5.4 Activation planner

`src/plugins/activation-planner.ts` 把一个触发点映射到应加载的插件：

- command
- provider
- agent harness
- channel
- route
- capability

它使用两类 reason：

- 显式 `activation.*` hints。
- manifest ownership fallback，例如 `manifest-provider-owner`、`manifest-channel-owner`、`manifest-command-alias`。

这避免请求时“加载所有插件再找谁能处理”。热路径应该携带已准备好的 provider/channel/capability 事实，而不是重复全局发现。

## 5.5 Metadata snapshot

`src/plugins/plugin-metadata-snapshot.ts` 建立 metadata-only snapshot。它包含 installed index、manifest registry、owner maps、normalizer 和 diagnostics，但不持有加载后的模块或 provider SDK。

这个 snapshot 的意义：

- Gateway 启动阶段复用同一份 manifest/index 事实。
- provider/channel/setup/doctor 等冷路径少重复扫描。
- runtime plugin loading 仍然独立，避免 stale runtime state 被 metadata cache 掩盖。

这是 OpenClaw 性能和边界设计的重点之一。

## 5.6 SDK surface

`src/plugin-sdk/index.ts` 明确写着 root SDK surface 要保持小；channel/provider helpers 应该走专门 subpath。`package.json` 的 exports 暴露大量 `openclaw/plugin-sdk/*` 子路径。

设计意图：

- 插件作者从 SDK contract 进入 core。
- bundled plugin 不应该 deep import core 私有模块。
- core 也不应该 deep import 插件私有实现。
- 如果需要新能力，先提升成 SDK seam 或 capability contract。

## 5.7 通道插件 contract

`src/channels/plugins/types.plugin.ts` 的 `ChannelPlugin` 是通道的完整能力表。它可以拥有：

- `config` / `configSchema`
- `setupWizard` / `setup`
- `pairing` / `security`
- `groups` / `mentions`
- `outbound`
- `status`
- `gatewayMethods` / `gateway`
- `auth`
- `commands`
- `lifecycle`
- `secrets`
- `allowlist`
- `doctor`
- `bindings` / `conversationBindings`
- `streaming`
- `threading`
- `message` / `messaging` / `actions`
- `directory`
- `agentTools`

通道插件因此不仅是“发送消息 adapter”，它拥有从配置、登录、访问控制、目录、线程、动作到 Gateway 方法的完整 surface。

## 5.8 共享 `message` tool

`docs/plugins/architecture.md` 描述当前边界：

- core 拥有共享 `message` tool host、prompt wiring、session/thread bookkeeping、execution dispatch。
- channel plugin 拥有 action discovery、schema contribution、capability discovery 和最终执行。

具体 adapter 是 `ChannelMessageActionAdapter.describeMessageTool(...)`。它可以根据 account、current channel、thread、message、session、agent、requester identity 返回当前可见 action 和参数。

这点很重要：core 不应该写 `if channel === "telegram"` 这种分支来决定消息工具能力。通道差异应在插件边界内表达。

## 5.9 插件安全边界

Native plugin in-process 运行，等同 Gateway 进程权限。`docs/plugins/architecture.md` 和 `docs/gateway/security/index.md` 都强调：插件安装就是运行代码。

对应风险：

- plugin 可以注册 tool、hook、HTTP route、service。
- plugin bug 可以 crash Gateway。
- 恶意 plugin 等价于 Gateway 进程内任意代码。

OpenClaw 的缓解手段是 allow/deny、明确 install sources、manifest/schema 校验、security audit、plugin allowlist 和 source provenance 约束，而不是进程级 sandbox。

## 5.10 插件生命周期的完整拆解

一个插件从“存在于磁盘”到“参与运行时”，通常经历：

1. discovery：扫描 bundled、installed、workspace 或 configured plugin。
2. manifest read：读取 `openclaw.plugin.json`，得到 id、kind、exports、capabilities、config schema、activation metadata。
3. metadata snapshot：把可静态读取的信息放进 snapshot，供 Gateway/UI/doctor/activation planner 使用。
4. enablement：结合 config、allow/deny、slot、official catalog、activation trigger 判断是否启用。
5. module load：真正 import 插件入口或 runtime surface。
6. registration：插件通过 `OpenClawPluginApi` 注册 provider/channel/tool/hook/context engine/HTTP route 等。
7. runtime use：agent run、Gateway method、channel event 或 sidecar 调用已注册 capability。
8. reload/dispose：配置变化或 Gateway shutdown 时，按插件声明和 registry 生命周期清理。

这个生命周期解释了为什么 OpenClaw 里“插件没加载”和“插件没启用”不是同义词。一个插件可能已被发现、有 metadata、有配置 UI，但 runtime code 还没进入进程。

## 5.11 Memory 和 context engine 插件为何特殊

Memory plugin 和 context engine plugin 都会影响模型看到的内容，但接入点不同：

- memory plugin 注册工具、backend、host runtime，让模型主动检索长期资料。
- context engine 注册 `ingest/assemble/compact/afterTurn`，直接改变本次 prompt 组装和压缩策略。

因此 context engine 的风险面更高：它可以让模型看不到某些历史，也可以把额外内容注入 `systemPromptAddition`。memory plugin 通常是按工具调用返回片段，除非再被 context engine 或 prompt builder 主动注入。

源码入口分别是：

- `extensions/memory-core/src/tools.ts`
- `src/plugin-sdk/memory-core*.ts`
- `src/context-engine/types.ts`
- `src/context-engine/registry.ts`

## 5.12 Channel plugin 与多 Agent routing 的连接点

通道插件不应该自己决定“哪个 agent 回答”。它应该提供足够准确的 channel/account/peer/thread/guild/team/roles 信息，让 `src/routing/resolve-route.ts` 做统一 routing。这样不同通道共享一套 binding 语义：

- peer 精确匹配。
- parent peer 继承。
- guild/team/roles 匹配。
- account/channel fallback。
- default agent。

这也是为什么 channel contract 里有 bindings、conversation binding、threading、directory 等看似很多的 adapter。它们最终都服务于统一 routing 和 session ownership。
