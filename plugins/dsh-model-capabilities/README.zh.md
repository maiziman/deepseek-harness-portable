# DSH 自定义 API 能力识别插件

[下载 v0.1.2](https://github.com/maiziman/deepseek-harness-portable/releases/tag/plugin-model-capabilities-v0.1.2) · [English](README.md)

**自动识别 OpenAI-compatible 自定义模型支持的思考等级与图像输入能力，不修改 DSH，也不覆盖明确设置。**

`@maiziman/dsh-model-capabilities` 是面向 `llm-pi-ai` 自定义提供方的独立可选 DeepSeek Harness Bundle。它只调用 Harness 的公开服务，不修改也不复制官方适配器，因此替换或升级官方 dsh 不会覆盖插件实现。

| 能力 | 行为 |
|---|---|
| **思考等级** | 先读取声明的等级元数据；策略允许时，只保存得到端点正面证据的等级。 |
| **图像输入** | 先读取声明的视觉元数据；局域网端点可用程序生成的内嵌测试图片验证识图能力。 |
| **明确设置优先** | 只补充缺失的能力字段，不替换用户或端点配置已经明确给出的值。 |
| **公网端点保持被动** | 默认只读取元数据，不向公网端点发起产生 token 的主动探测。 |
| **独立生命周期** | 使用官方 `dsh plugin` 命令安装，拥有独立安装包、校验和、兼容性验证与 Release。 |

## 能力识别方式

用户保存 OpenAI Completions 兼容提供方后，插件观察官方 `llm-pi-ai` 设置分节；其他提供方协议会被忽略。插件先读取端点公开的能力元数据，再通过带 revision 的局部写入更新该提供方的 `models` 数组。它只补充缺失的 `input` 或 `reasoningEfforts`；用户明确填写的值始终优先，包括 `reasoningEfforts: false` 和 `input: [text]`。

插件能够读取 OpenRouter 的 `architecture.input_modalities`、`supported_parameters` 和 `reasoning.supported_efforts`，通用 OpenAI 兼容端点的 `supported_parameters: [reasoning_effort]`，以及 Ollama `/api/show` 返回的 `vision`、`thinking` 能力。模型名称不会被当成判断依据。

如果使用字面本机或局域网地址的端点没有提供完整元数据，Bundle 默认会在插件启动、设置文件变化或该路由的凭据引用变化后发起少量后台 Chat Completions 请求。只有服务器拒绝无效的探测值、且有效请求返回思考字段时，相应思考等级才会写入；只有模型对两张随机排序的内嵌测试 PNG 都返回准确的单个颜色词时，图像输入才会写入，解释性或含糊回答会判定失败。这些请求不会阻塞程序启动，并且同一进程中每组提供方、模型和凭据配置只尝试一次。

公网端点默认只读取不产生 token 的元数据，避免静默产生付费推理请求。只有确认端点允许额外请求和相应 token 消耗时，才应把 `activeProbePolicy` 改为 `always`。

## 安装

DeepSeek Harness 纯净便携 ZIP 不内置、也不会自动安装这个插件。请从 [DSH 自定义 API 能力识别插件 v0.1.2 Release](https://github.com/maiziman/deepseek-harness-portable/releases/tag/plugin-model-capabilities-v0.1.2) 下载带版本号的压缩包与校验和，再通过官方 Bundle 流程核验并安装：

```powershell
$version = '0.1.2'
$package = "maiziman-dsh-model-capabilities-$version.tgz"
$release = "https://github.com/maiziman/deepseek-harness-portable/releases/download/plugin-model-capabilities-v$version"
Invoke-WebRequest "$release/$package" -OutFile $package
Invoke-WebRequest "$release/SHA256SUMS.txt" -OutFile SHA256SUMS.txt
$expected = ((Get-Content SHA256SUMS.txt -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash $package -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw '插件校验和不一致' }
.\dsh.cmd plugin --profile web add ".\$package" --offline
.\dsh.cmd --profile web --dump-config
```

关闭 `DeepSeek-Harness.exe` 后，请在 Pure Portable 解压目录中运行这些命令，完成后重新打开 EXE。Pure Portable 会让这条官方命令使用包内固定哈希的 pnpm；已经下载的 `.tgz` 不需要访问 registry。如果使用单独的全局 dsh 安装，请把 `.\dsh.cmd` 替换为 `dsh`。升级时使用新版插件 Release 重复执行安装命令即可。插件 Release 与便携 ZIP Release 使用各自独立的版本和校验和。

本地开发时可直接安装当前目录：

```sh
dsh plugin --profile web add ./plugins/dsh-model-capabilities
dsh --profile web --dump-config
```

包清单声明了 `dsh.bundle.patch`，`cordis.patch.yml` 会把插件作为后置组合行插入。卸载不会清除已经识别并保存到模型设置中的能力：

```sh
.\dsh.cmd plugin --profile web remove @maiziman/dsh-model-capabilities --offline
```

单独的全局 dsh 安装请把 `.\dsh.cmd` 替换为 `dsh`。

## 配置

Bundle 默认配置如下：

```yaml
- insert:
    - id: model-capabilities
      name: '@maiziman/dsh-model-capabilities'
      config:
        metadataDiscovery: true
        activeProbePolicy: local-only
        reasoningProbe: true
        visionProbe: true
        reasoningProbeEfforts: [low, high, max]
        probeConcurrency: 1
        requestTimeoutMs: 10000
        probeMaxTokens: 128
```

| 字段 | 作用 |
|---|---|
| `metadataDiscovery` | 读取不产生模型输出的能力元数据。 |
| `activeProbePolicy` | 可选 `never`、`local-only` 或 `always`；`local-only` 只包含准确的 `localhost` 以及字面回环、链路本地、RFC 1918 和 IPv6 本地地址。DNS 名称需要使用 `always`。 |
| `reasoningProbe` | 在主动探测策略允许时检查思考能力。 |
| `visionProbe` | 在主动探测策略允许时检查内嵌图像输入。 |
| `reasoningProbeEfforts` | 分别测试的思考等级；只有得到正面证据的等级会保存。 |
| `probeConcurrency` | 同一模型同时进行的思考探测上限。 |
| `requestTimeoutMs` | 每个元数据请求或主动请求的超时时间。 |
| `probeMaxTokens` | 探测请求允许的最大输出 token 数。 |

如需修改默认值，可在 profile 自己的 `cordis.patch.yml` 中按 `model-capabilities` 行 ID 覆盖。后置行会整体替换前一行的配置，因此需要完整重写希望保留的字段。

## 安全与隐私

API Key 通过 `ctx.credentials` 解析，只进入请求头，不会写回模型设置或日志。请求拒绝重定向，响应最大读取 2 MiB，请求时间有上限，插件卸载时会取消仍在进行的请求。相关设置或凭据变化会取消上一轮能力识别，过期响应会被丢弃；带 revision 的写入失败后仍允许重试。插件能够识别由自身写入产生的设置通知，因此一次成功写入不会重复探测。如果凭据恰好在一次已受理的写入仍在落盘时变化，该轮由插件新增的字段会保持待确认状态；下一轮会重新验证，并且只撤回仍未被用户改动、同时已失去正面证据的新增字段。删除对应提供方或模型会同时清除这份待确认归属。其他端点错误不会修改当前模型设置。

图像探测通过两次请求发送程序内置生成的 32 × 32 纯色 PNG，不读取或上传用户文件；思考探测使用固定算术题，并增加一次无效值检查。将 `activeProbePolicy` 设为 `never` 可完全关闭产生模型输出的请求。

## 测试

```sh
npm test
npm pack --dry-run
```

测试覆盖元数据格式、局域网地址识别、需要正面证据的主动探测、显式设置保护、凭据读取以及带 revision 的写入。

## 兼容性

| DeepSeek Harness | 验证方式 |
|---|---|
| `0.1.1-rc.2` | 官方 Bundle 登记、profile 启动、设置写入与成品运行时测试。 |
| `0.1.2-alpha.1`（`cd5ef814`） | 使用该精确源码标签的官方 `dsh plugin` 命令全新安装 v0.1.1 Release 压缩包，完成完整 `--dump-config`、profile 启动、Settings/Credentials API 审查、更新事件时序回归与分层 `compat` 回归。 |
| `0.1.2-alpha.2`（`0a53fb55`） | 全新安装本 v0.1.2 压缩包，完成完整 profile 启动，并通过真实本地 OpenAI-compatible 模型识别图像输入、思考等级与 `compat.thinkingFormat`。 |

每个插件 Release 标签都会按照 [`.github/plugin-compatibility.json`](../../.github/plugin-compatibility.json) 中固定的官方标签、提交和哈希固定的 pnpm 版本，重新执行全新安装、展开配置检查和 Web profile 启动。创建 Draft 前与正式公开前都会重新解析官方标签，并要求它仍指向同一提交。流程还会构建纯净便携 ZIP，拒绝任何已经内置该插件的 ZIP，然后在不依赖全局 pnpm 或 Corepack 缓存的环境中，通过该 ZIP 以离线模式安装精确插件候选；任一道验证失败都不会公开 Release。

Harness 仍处于预发布阶段，未来如果官方调整设置结构，插件可能需要同步升级；遇到验证失败或并发编辑时，插件会保留原设置，不影响上一份有效提供方配置继续工作。便携版发布跟踪与插件相互独立，不会安装或更新这个 Bundle。
