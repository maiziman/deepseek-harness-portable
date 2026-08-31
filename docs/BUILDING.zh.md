# 构建 CedarDSH Desktop

本文档说明便携 ZIP 的组装、验证和发布方式。安装与日常使用请从 [项目 README](../README.zh.md) 开始。

## 环境要求

- Windows 10 或更高版本，x64
- PowerShell 7.2 或更高版本（`build-portable.ps1` 与 `verify-package.ps1` 会强制检查）
- 可访问 npm registry 和所选 Electron 二进制镜像；从官方源码打包时还需访问 GitHub
- 有足够空间存放 Node.js 运行时、生产依赖、Electron 和最终 ZIP

## 构建

```powershell
.\build-portable.ps1
```

| 参数 | 含义 |
|---|---|
| `-DshVersion 0.1.1-rc.2` | 已发布的 `@deepseek-ai/dsh` 版本；默认取 npm 最新版。 |
| `-DshPackageDirectory C:\Build\dsh-packages` | 可选的完整包集合，由精确官方 `dsh-v*` 标签暂存而来；不提供时从 npm 安装 `@deepseek-ai/dsh`。 |
| `-DshSourceTag dsh-v0.1.2-alpha.2` | 记录在暂存包来源信息中并与其核对的精确官方源码标签；使用 `-DshPackageDirectory` 时必须提供。 |
| `-DshSourceSha 0a53fb55...` | 官方源码标签对应的完整 40 位提交；使用 `-DshPackageDirectory` 时必须提供。 |
| `-PortableVersion 1.2.1` | 项目发布版本，用于标签、ZIP、Electron 元数据、manifest 和更新比较；无标签的本地构建默认与 dsh 版本相同。 |
| `-NodeVersion v24.19.0` | 满足 dsh engines 要求的官方 Node.js 版本。 |
| `-ElectronVersion 44.0.0` | Electron 运行时版本。 |
| `-ElectronMirror npmmirror` | Electron 来源：`npmmirror`、`github` 或自定义镜像 URL。 |
| `-SkipSmoke` | 跳过包内真实启动探测。 |
| `-ForceDownloadNode` | 重新下载 Node.js，并再次执行官方校验。 |

构建会写入 `dist\DeepSeek-Harness-win64-v<便携版本>.zip` 和 `dist\SHA256SUMS.txt`。ZIP 内的 `manifest.json` 会分别记录 `portableVersion` 与官方 `dshVersion`，以及 Node.js、pnpm、Electron 版本、pnpm 包哈希、提供来源时的上游源码标签与提交、关键输入和二进制文件的 SHA256。带标签发布时，Release 标签、ZIP 与 `portableVersion` 必须使用同一个语义版本。

源码包构建会保持选定的官方 checkout 不变。上游自己的 `release:verify`、`build:official` 与 `release:pack` 命令生成 `dsh`、`vendor` 和 `landlock` 三组压缩包；`.github/scripts/stage-official-dsh-packages.ps1` 随后写出一个封闭的包目录，其中包含这些压缩包、`provenance.json` 和 `SHA256SUMS.txt`。如果压缩包缺失、包名重复、分组异常、版本或源码不匹配、大小不符或校验失败，便携构建会终止。

只读源码任务随后会把每个已打包运行包映射回经过验证的官方 lockfile importer，推导生产依赖、可选依赖与必需 peer 组成的图，并且只移除源码工作区中声明的平台规则明确排除 Windows x64 的可选包。任务会生成唯一的规范 consumer manifest、workspace policy 与 lockfile，再把精确内部包集合、每条外部 registry 解析记录、package 元数据、snapshot 依赖边、两套运行模型 SHA256 和三份 consumer 文件的 SHA256 写入 schema 4 来源记录。另一套 consumer 控制模型会记录 lockfile 版本、根 importer 的 specifier 与解析版本、根 settings、全部 override 和每个 patched dependency 的内容哈希，并用规范 SHA256 固定完整模型。package 元数据包含平台与 libc 规则、engines、是否存在可执行入口、bundled dependency、deprecated、身份、peer 声明与 peer 元数据；不支持的 package、snapshot、importer、setting、override、patch 或 lock 根字段会直接失败。两个 Windows 构建都会复制并重新验证整个目录，将规范 lock 与记录的内部、外部和 consumer 控制模型逐项比较，从官方 npm registry 取得内容，再执行 frozen、offline、hoisted 安装。只有完整 lockfile 哈希与语义模型全部通过后，安装才使用 pnpm 的 trusted-lock 模式，因此 pnpm 不会再访问电脑级 registry 获取元数据。安装后不修改上游可执行文本或运行配置，只把生成的 CSS 源码分区注释改成仓库相对路径，并删除 pnpm shim 的目标注释；负例测试会证明这两项隐私处理保留可执行文本。最终的二进制安全扫描还会在任何成品文件中拒绝真实仓库、scratch、包输入、runner 或临时目录路径，包括斜杠归一化、转义、URI 与 UTF-16 形式。

```powershell
.\build-portable.ps1 `
  -DshVersion 0.1.2-alpha.2 `
  -PortableVersion 1.2.1 `
  -DshPackageDirectory C:\Build\dsh-packages `
  -DshSourceTag dsh-v0.1.2-alpha.2 `
  -DshSourceSha 0a53fb55bea101816fa226bb964ae2bed71c343b
```

## 组装流程

```text
build-portable.ps1
 ├─ 解析并校验组件版本
 ├─ 校验官方标签包集合及其规范 Windows lock，或解析已发布的指定 npm 包
 ├─ 校验透明图标母版并生成 9 档 Windows 图标
 ├─ 下载官方 Windows x64 Node.js 运行时并验证 SHA256
 ├─ 取得已验证 lock 的内容，以 frozen、offline 方式安装为适合 ZIP 的扁平目录树，并加入只供明确插件命令使用的固定哈希 pnpm
 ├─ 从非执行生成注释中移除构建机路径
 ├─ 打包 Electron 桌面壳，并验证 PE 图标、产品名、原文件名和版本元数据
 ├─ 组装 runtime/、app/、dsh-home/、workspace/、第三方声明、README.txt 和 dsh.cmd
 ├─ 启动包内应用，等待本地服务并捕获渲染后的界面
 └─ 生成 ZIP 和 SHA256SUMS.txt
```

默认 ZIP 不含能力插件，启动时也不会安装插件。固定哈希 pnpm 只用于用户明确执行的官方 `dsh plugin` 命令，避免退回 Corepack 或电脑上的全局包管理器。桌面壳会先渲染启动页，再使用内置 Node.js 运行 `dsh web --no-open --port 0`。启动页显示可观测到的目录、运行时、profile 组件、profile、服务和界面阶段以及累计时间；首次创建后备组件链接时，还会把已完成的包内链接数量与构建冒烟测试记录在 `manifest.json` 中的总数比较。桌面壳读取服务输出的本机 URL 后在窗口中打开；再次启动会聚焦已有窗口，关闭窗口会终止整个服务进程树。

## 自动跟踪上游版本

`dsh-upstream-watch` 工作流每六小时运行一次，也支持手动启动。它从官方 `deepseek-ai/deepseek-harness` 仓库的 `dsh-v*` Git 标签中按语义版本选择最高版本，并记录该标签对应的 commit。工作流 checkout 这个精确提交，确认标签、根版本、CLI 版本与声明的 pnpm 版本一致，再执行上游 `release:verify`、`build:official` 与 `release:pack` 流程；它无需等待同版本出现在 npm，也不会使用 npm `latest` 或 `next` 识别上游版本。

尚无完整公开便携包的官方标签，会在上游包集合通过源码与来源校验后进入 Windows Server 2022 与 2025 构建验证矩阵。两个环境各自完成独立构建后，第二道双运行器检查会下载准备公开的同一个 Windows 2025 产物，并在两个 Windows 版本上再次验证。跟踪器会在最高的完整公开严格 `v<语义版本>` 便携版之后分配下一个补丁版本；历史 `v1.0.0` 至 `v1.2.0` 的编号不一致只对已经公开的 `v0.1.1-rc.2` ZIP 生效，因此第一个新格式自动包是 `v1.2.1`。Release 标签、ZIP、正文标记、Electron 版本、manifest 中的便携版本和 GitHub prerelease 状态都跟随便携版本；正文与 manifest 会另外记录官方 dsh 版本、来源标签、精确来源提交和上游预览标识。

两个环境全部通过后，工作流会进入与人工便携标签共用的发布锁，重新扫描公开 Release，确认 dsh 映射和补丁版本分配仍然有效。它会在生成说明前把前一便携标签解析为精确 commit，再使用隔离的临时标签创建私有 Draft Release，并保留精确 Release ID。最终步骤要求远端只有一个对应 ZIP 与 `SHA256SUMS.txt`，且上传状态、大小和远端 SHA256 摘要都与已验证的本地文件一致。正式公开前一刻，自动与人工路径都会再次扫描公开 Release，要求版本分配仍与原记录完全一致，并确认前一标签仍指向记录的 commit。暂存步骤会记录 Draft 正文与标题的 SHA256；最终程序会再次核对两者，并在指定公开 `v<便携版本>` 标签与发布 Release 的同一次 API 修改中写回已验证的值。由便携或插件标签触发的运行要求触发标签始终留在原 commit，只有自动跟踪器可以创建尚不存在的正式标签。整个流程不会删除或替换任何 Release 附件；重跑遇到完整公开 Release 时只读校验，中断留下的私有 Draft 也不会阻塞后续运行。构建任务只有仓库只读权限，也不会保留 Git 凭据。

便携程序只读取严格 `v<语义版本>` 标签、ZIP 版本和附件上传记录相互一致的完整公开 Release。它每 24 小时最多检查一次，把最高的有效便携版本与 `manifest.json` 比较；尚无 `portableVersion` 字段的旧包会回退使用原有 `dshVersion`。因此，即使 dsh 依赖不变，桌面壳修复也能触发新版提示。程序只会询问是否打开下载页，不会自动下载或替换文件。如需禁用联网检查，可在启动前设置 `DSH_UPDATE_CHECK=0`。

## 验证

```powershell
.\verify-package.ps1
.\verify-package.ps1 -ZipPath .\dist\DeepSeek-Harness-win64-v1.2.1.zip -ExpectedPortableVersion 1.2.1 -ExpectedDshVersion 0.1.2-alpha.2
```

如果图标母版不同时包含透明和不透明像素、ICO 不是由 16、20、24、32、40、48、64、128 和 256 px 共 9 档 RGBA PNG 组成，或最终 EXE 的 PE 图标组与任一源图帧不同，构建都会终止。压缩前，构建会对真实仓库、构建专用 scratch、runner 工作区与包输入路径执行完整的二进制敏感扫描。扫描不会把电脑级用户主目录或临时目录前缀本身判为泄漏，因为第三方原生二进制可能合法保留其上游构建使用的通用前缀。验证探针还会检查唯一顶层目录、启动前没有 reparse point、`dsh-home` 为空、解压完整性、第三方声明、manifest 与 Node.js/pnpm 版本、规范 lock 与运行图哈希、EXE 产品名和原文件名、生成文件中没有绝对路径注释、包管理器状态与默认插件缺失、真实服务启动、URL 发现、干净退出和首次 profile 初始化。它同时捕获界面截图与机器可读的启动证据，证明实际显示的组件分子和分母来自包内链接，并与 manifest 总数一致。

GitHub Actions 会在全新的 Windows Server 2022 和 2025 runner 上重复构建与验证。分支推送会在一次运行中选择最高的官方 `dsh-v*` 标签，并上传短期工作流产物。上游跟踪器的可选手动版本只用于断言当前唯一最高的官方标签，不能把历史 dsh 版本发布到继续向前的更新流。`v*` 标签会把自身版本作为 `portableVersion`，读取提交中的 `.github/portable-dsh-version.txt` 精确 dsh 版本，再把该版本解析为官方来源标签和 commit；创建人工便携版标签前需要先更新这个文件。自动发布说明只与前一个使用严格 `v<语义版本>` 标签且附件完整的公开便携版比较，不会选中发布失败或无关的标签系列。上游跟踪流程沿用同一条递增的 `v*` 版本流，在官方标签源码通过上游构建、打包和便携版验证后发布下一个补丁版本。

GitHub runner 使用 Windows Server。应定期在 Windows 10 或 11 上抽查已发布的 ZIP，包括 SmartScreen 和常见杀毒软件的表现。

## 仓库结构

```text
.
├─ build-portable.ps1       构建、组装、冒烟与压缩
├─ verify-package.ps1       确定性的兼容性探针
├─ watch-progress.ps1       本地长时间构建的简洁进度输出
├─ shell/                   Electron 桌面壳与应用图标
├─ .github/workflows/       全新系统矩阵与标签发布
├─ docs/                    README 与社交分享图片
└─ dist/ .build/ .cache/    已忽略的生成文件
```
