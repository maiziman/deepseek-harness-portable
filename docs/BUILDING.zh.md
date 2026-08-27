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
| `-NodeVersion v24.19.0` | 满足 dsh engines 要求的官方 Node.js 版本。 |
| `-ElectronVersion 44.0.0` | Electron 运行时版本。 |
| `-ElectronMirror npmmirror` | Electron 来源：`npmmirror`、`github` 或自定义镜像 URL。 |
| `-SkipSmoke` | 跳过包内真实启动探测。 |
| `-ForceDownloadNode` | 重新下载 Node.js，并再次执行官方校验。 |

构建会写入 `dist\DeepSeek-Harness-win64-v<dsh版本>.zip` 和 `dist\SHA256SUMS.txt`。ZIP 内的 `manifest.json` 会记录 dsh、Node.js、Electron 版本及关键二进制文件的 SHA256。

## 组装流程

```text
build-portable.ps1
 ├─ 解析并校验组件版本
 ├─ 下载官方 Windows x64 Node.js 运行时并验证 SHA256
 ├─ 把生产依赖安装为适合 ZIP 的扁平目录树
 ├─ 打包 Electron 桌面壳
 ├─ 组装 runtime/、app/、dsh-home/、workspace/、README.txt 和 dsh.cmd
 ├─ 启动包内应用，等待本地服务并捕获渲染后的界面
 └─ 生成 ZIP 和 SHA256SUMS.txt
```

桌面壳会先渲染启动页，再使用内置 Node.js 运行 `dsh web --no-open --port 0`。启动页显示可观测到的目录、运行时、profile 组件、profile、服务和界面阶段以及累计时间；首次创建后备组件链接时，还会把已完成数量与构建冒烟测试记录在 `manifest.json` 中的总数比较。桌面壳读取服务输出的本机 URL 后在窗口中打开；再次启动会聚焦已有窗口，关闭窗口会终止整个服务进程树。

## 自动跟踪上游版本

`dsh-upstream-watch` 工作流每六小时运行一次，也支持手动启动。它读取官方 npm 的 `latest` 标签，再检查公开和草稿 Release 中是否已有对应的便携 ZIP。未打包的版本会进入 Windows Server 2022 与 2025 构建验证矩阵。

两个环境全部通过后，工作流会暂存一个私有的 `dsh-v<版本>` Draft Release，定时任务随后再次确认该版本仍是官方 npm 的 `latest`。最终发布步骤只处理这一个 Draft ID，并要求远端只有一个 ZIP 与 `SHA256SUMS.txt`，且上传状态、大小和远端 SHA256 摘要都与已验证的本地文件一致。预检会阻止重跑任务修改现有的公开 Release。任何失败都会让草稿保持私有以便后续重试；构建任务只有仓库只读权限，也不会保留 Git 凭据。

便携程序只读取已经公开的 Release。它每 24 小时最多检查一次，把最高的有效便携包版本与 `manifest.json` 比较；发现新版时先询问是否打开下载页，不会自动下载或替换文件。如需禁用联网检查，可在启动前设置 `DSH_UPDATE_CHECK=0`。

## 验证

```powershell
.\verify-package.ps1
.\verify-package.ps1 -ZipPath .\dist\DeepSeek-Harness-win64-v0.1.1-rc.2.zip
```

验证探针会检查解压完整性、manifest 与运行时版本、启动进度页和最终 UI 的截图、真实服务启动、URL 发现、干净退出和首次 profile 初始化，并要求初始化后的组件链接数量与包内 manifest 一致。

GitHub Actions 会在全新的 Windows Server 2022 和 2025 runner 上重复构建与验证。普通推送会上传短期工作流产物；`v*` 标签会把 ZIP 和校验和发布到 GitHub Release，上游跟踪流程会在发现新的官方 dsh 版本后自动公开经过验证的 Release。

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
