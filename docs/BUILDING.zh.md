# 构建与验证

本文档说明便携 ZIP 的组装、验证和发布方式。安装与日常使用请从[项目 README](../README.zh.md) 开始。

## 环境要求

- Windows 10 或更高版本，x64
- PowerShell 7 或 Windows PowerShell 5.1
- 可访问 npm registry 和所选 Electron 二进制镜像
- 有足够空间存放 Node.js 运行时、生产依赖、Electron 和最终 ZIP

## 构建

```powershell
.\build-portable.ps1
```

| 参数 | 含义 |
|---|---|
| `-DshVersion 0.1.1-rc.2` | 已发布的 `@deepseek-ai/dsh` 版本；默认取 npm 最新版。 |
| `-PortableVersion 1.2.1` | 项目发布版本，用于标签、ZIP、Electron 元数据、manifest 和更新比较；无标签的本地构建默认与 dsh 版本相同。 |
| `-NodeVersion v24.19.0` | 满足 dsh engines 要求的官方 Node.js 版本。 |
| `-ElectronVersion 44.0.0` | Electron 运行时版本。 |
| `-ElectronMirror npmmirror` | Electron 来源：`npmmirror`、`github` 或自定义镜像 URL。 |
| `-SkipSmoke` | 跳过包内真实启动探测。 |
| `-ForceDownloadNode` | 重新下载 Node.js，并再次执行官方校验。 |

构建会写入 `dist\DeepSeek-Harness-win64-v<便携版本>.zip` 和 `dist\SHA256SUMS.txt`。ZIP 内的 `manifest.json` 会分别记录 `portableVersion` 与官方 `dshVersion`，以及 Node.js、Electron 版本和关键二进制文件的 SHA256。带标签发布时，Release 标签、ZIP 与 `portableVersion` 必须使用同一个语义版本。

## 组装流程

```text
build-portable.ps1
 ├─ 解析并校验组件版本
 ├─ 校验透明图标母版并生成 9 档 Windows 图标
 ├─ 下载官方 Windows x64 Node.js 运行时并验证 SHA256
 ├─ 把生产依赖安装为适合 ZIP 的扁平目录树
 ├─ 打包 Electron 桌面壳，并把 PE 中每档图标与源 ICO 逐一比对
 ├─ 组装 runtime/、app/、dsh-home/、workspace/、第三方声明、README.txt 和 dsh.cmd
 ├─ 启动包内应用，等待本地服务并捕获渲染后的界面
 └─ 生成 ZIP 和 SHA256SUMS.txt
```

桌面壳会先渲染启动页，再使用内置 Node.js 运行 `dsh web --no-open --port 0`。启动页显示可观测到的目录、运行时、profile 组件、profile、服务和界面阶段以及累计时间；首次创建后备组件链接时，还会把已完成数量与构建冒烟测试记录在 `manifest.json` 中的总数比较。桌面壳读取服务输出的本机 URL 后在窗口中打开；再次启动会聚焦已有窗口，关闭窗口会终止整个服务进程树。

## 自动跟踪上游版本

`dsh-upstream-watch` 工作流每六小时运行一次，也支持手动启动。它从官方 `deepseek-ai/deepseek-harness` 仓库的 `dsh-v*` Git 标签中按语义版本选择最高版本，并记录该标签对应的 commit。如果 npm registry 尚未提供完全相同版本的 `@deepseek-ai/dsh`，本次任务会报告等待中的标签并正常结束，后续定时任务继续检查。这样既不依赖 npm 的 `latest` 或 `next` dist-tag，也不会尝试安装尚不存在的包。

精确 npm 包出现后，尚无完整公开便携包的版本会进入 Windows Server 2022 与 2025 构建验证矩阵。跟踪器会在最高的完整公开严格 `v<语义版本>` 便携版之后分配下一个补丁版本；历史 `v1.0.0` 至 `v1.2.0` 的编号不一致只作为迁移基准，因此第一个新格式自动包是 `v1.2.1`。Release 标签、ZIP、正文标记、Electron 版本与 manifest 中的便携版本必须一致；正文会另外记录官方 dsh 版本、来源标签和精确来源提交。如果包内 dsh 是预览版，即使分配到的便携标签没有预览后缀，GitHub Release 仍会标记为 prerelease。

两个环境全部通过后，工作流会进入与人工便携标签共用的发布锁，重新扫描公开 Release，确认 dsh 映射和补丁版本分配仍然有效。随后它使用隔离的临时标签创建私有 Draft Release，并保留精确 Release ID。最终步骤要求远端只有一个对应 ZIP 与 `SHA256SUMS.txt`，且上传状态、大小和远端 SHA256 摘要都与已验证的本地文件一致；Draft 正文与目标提交也会在公开前用 SHA256 固定，然后在一次 API 修改中指定公开的 `v<便携版本>` 标签。整个过程不会删除或替换任何 Release 附件；重跑遇到完整公开 Release 时只读校验，中断留下的私有 Draft 也不会阻塞后续运行。构建任务只有仓库只读权限，也不会保留 Git 凭据。

便携程序只读取严格 `v<语义版本>` 标签、ZIP 版本和附件上传记录相互一致的完整公开 Release。它每 24 小时最多检查一次，把最高的有效便携版本与 `manifest.json` 比较；尚无 `portableVersion` 字段的旧包会回退使用原有 `dshVersion`。因此，即使 dsh 依赖不变，桌面壳或插件修复也能触发新版提示。程序只会询问是否打开下载页，不会自动下载或替换文件。如需禁用联网检查，可在启动前设置 `DSH_UPDATE_CHECK=0`。

## 独立插件发布

模型能力 Bundle 使用独立的 `plugin-model-capabilities-v<版本>` 标签和 GitHub Release。`plugin-release` 工作流要求标签版本与 `plugins/dsh-model-capabilities/package.json` 完全一致，运行插件测试，确认 npm 压缩包只包含 7 个发布文件，并生成单行 `SHA256SUMS.txt`。随后，它会在 `.github/plugin-compatibility.json` 固定的精确上游标签和提交中，通过官方 CLI 把该压缩包安装到全新环境，展开 Web profile 并验证命令可以启动。全部检查通过后，工作流才在使用隔离临时标签的私有 Draft 中暂存 `.tgz` 和校验和，核对远端文件的精确大小与 SHA256 摘要，再指定公开插件标签，同时关闭 GitHub Latest 标记；语义版本中的预览标识也会同步到 GitHub prerelease 状态。便携版 Release 继续遵守独立的 ZIP 加校验和附件规则与版本周期。

## 验证

```powershell
.\verify-package.ps1
.\verify-package.ps1 -ZipPath .\dist\DeepSeek-Harness-win64-v1.2.1.zip -ExpectedPortableVersion 1.2.1 -ExpectedDshVersion 0.1.2-alpha.1
```

如果图标母版不同时包含透明和不透明像素、ICO 不是由 16、20、24、32、40、48、64、128 和 256 px 共 9 档 RGBA PNG 组成，或最终 EXE 的 PE 图标组与任一源图帧不同，构建都会终止。验证探针随后检查解压完整性、包内第三方声明、manifest 与运行时版本、启动进度页和最终 UI 的截图、真实服务启动、URL 发现、干净退出和首次 profile 初始化，并要求初始化后的组件链接数量与包内 manifest 一致。

GitHub Actions 会在全新的 Windows Server 2022 和 2025 runner 上重复构建与验证。分支推送会在一次运行中固定 npm `latest`，并上传短期工作流产物。`v*` 标签会把自身版本作为 `portableVersion`，并读取提交中的 `.github/portable-dsh-version.txt` 精确 dsh 版本，因此重跑同一标签不会悄悄改变任一身份；创建人工便携版标签前需要先更新该文件。自动发布说明只与前一个使用严格 `v<语义版本>` 标签且附件完整的公开便携版比较，不会选中发布失败的标签，也不会混入旧上游或插件标签系列。上游跟踪流程沿用同一条递增的 `v*` 版本流，在新的官方 dsh 包可以安装后发布经过验证的下一个补丁版本。`plugin-model-capabilities-v*` 标签只运行独立插件发布流程。

GitHub runner 使用 Windows Server。应定期在 Windows 10 或 11 上抽查已发布的 ZIP，包括 SmartScreen 和常见杀毒软件的表现。

## 仓库结构

```text
.
├─ build-portable.ps1       构建、组装、冒烟与压缩
├─ verify-package.ps1       确定性的兼容性探针
├─ watch-progress.ps1       本地长时间构建的简洁进度输出
├─ plugins/                 可独立安装的 Bundle
├─ shell/                   Electron 桌面壳与应用图标
├─ .github/workflows/       全新系统矩阵与标签发布
├─ docs/                    README 与社交分享图片
└─ dist/ .build/ .cache/    已忽略的生成文件
```
