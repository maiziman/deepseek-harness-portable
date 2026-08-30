# DeepSeek Harness 模型能力插件

[English](README.md)

`@maiziman/dsh-model-capabilities` 是一个独立的 DeepSeek Harness Bundle，用于为 `llm-pi-ai` 自定义提供方识别思考控制和图像输入能力。它只调用 Harness 的公开服务，不修改也不复制官方适配器，因此替换或升级官方 dsh 不会覆盖插件实现。

## 它会修改什么

用户保存 OpenAI Completions 兼容提供方后，插件观察官方 `llm-pi-ai` 设置分节；其他提供方协议会被忽略。插件先读取端点公开的能力元数据，再通过带 revision 的局部写入更新该提供方的 `models` 数组。它只补充缺失的 `input` 或 `reasoningEfforts`；用户明确填写的值始终优先，包括 `reasoningEfforts: false` 和 `input: [text]`。

插件能够读取 OpenRouter 的 `architecture.input_modalities`、`supported_parameters` 和 `reasoning.supported_efforts`，通用 OpenAI 兼容端点的 `supported_parameters: [reasoning_effort]`，以及 Ollama `/api/show` 返回的 `vision`、`thinking` 能力。模型名称不会被当成判断依据。

如果使用字面本机或局域网地址的端点没有提供完整元数据，Bundle 默认会在插件启动、设置文件变化或该路由的凭据引用变化后发起少量后台 Chat Completions 请求。只有服务器拒绝无效的探测值、且有效请求返回思考字段时，相应思考等级才会写入；只有模型对两张随机排序的内嵌测试 PNG 都返回准确的单个颜色词时，图像输入才会写入，解释性或含糊回答会判定失败。这些请求不会阻塞程序启动，并且同一进程中每组提供方、模型和凭据配置只尝试一次。

公网端点默认只读取不产生 token 的元数据，避免静默产生付费推理请求。只有确认端点允许额外请求和相应 token 消耗时，才应把 `activeProbePolicy` 改为 `always`。

## 安装

便携 ZIP 已经内置这个 Bundle。使用官方 npm 方式安装 DeepSeek Harness 时，可从 [v0.1.0 插件 Release](https://github.com/maiziman/deepseek-harness-portable/releases/tag/plugin-model-capabilities-v0.1.0)下载带版本号的插件压缩包与校验和，再通过官方 Bundle 流程核验并安装：

```powershell
$version = '0.1.0'
$package = "maiziman-dsh-model-capabilities-$version.tgz"
$release = "https://github.com/maiziman/deepseek-harness-portable/releases/download/plugin-model-capabilities-v$version"
Invoke-WebRequest "$release/$package" -OutFile $package
Invoke-WebRequest "$release/SHA256SUMS.txt" -OutFile SHA256SUMS.txt
$expected = ((Get-Content SHA256SUMS.txt -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash $package -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw '插件校验和不一致' }
dsh plugin --profile web add ".\$package"
dsh --profile web --dump-config
dsh --profile web
```

升级时使用新版插件 Release 重复执行同一命令即可。插件 Release 与便携 ZIP Release 相互独立，因此插件可以在不改变包内 dsh 版本的情况下单独升级。

本地开发时可直接安装当前目录：

```sh
dsh plugin --profile web add ./plugins/dsh-model-capabilities
dsh --profile web --dump-config
```

便携版桌面程序会内置这个目录，并把七个发布文件暂存到 Web profile 内。首次创建 profile 时会自动执行同一套官方本地包登记流程；插件版本变化后则刷新暂存文件。如果便携目录发生移动，启动器会根据 profile 中的相对依赖声明修复 pnpm 生成的链接，然后再启动 Harness。

包清单声明了 `dsh.bundle.patch`，`cordis.patch.yml` 会把插件作为后置组合行插入。卸载不会清除已经识别并保存到模型设置中的能力：

```sh
dsh plugin --profile web remove @maiziman/dsh-model-capabilities
```

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
| `0.1.1-rc.2` | 便携版登记、profile 启动、设置写入与成品运行时测试。 |
| `0.1.2-alpha.1`（`cd5ef814`） | 使用该精确源码标签的官方 `dsh plugin` 命令在全新环境安装最终 `.tgz`，完成完整 `--dump-config`、profile 启动、Settings/Credentials API 审查、更新事件时序回归与分层 `compat` 回归。 |

每个插件 Release 标签都会按照 [`.github/plugin-compatibility.json`](../../.github/plugin-compatibility.json) 中固定的官方标签、提交和 pnpm 版本，重新执行全新安装、展开配置检查和 Web profile 启动；这道验证失败时不会公开 Release。

如果官方 Git 标签早于其精确 npm 包发布，便携版更新流程会等待这个包，而不会构建其他版本。Harness 仍处于预发布阶段，未来如果官方调整设置结构，插件可能需要同步升级；遇到验证失败或并发编辑时，插件会保留原设置，不影响上一份有效提供方配置继续工作。
