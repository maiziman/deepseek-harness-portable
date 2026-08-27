<p align="center">
  <img src="docs/social-preview.png" alt="DeepSeek Harness Portable：免安装的 Windows 桌面程序" width="100%">
</p>

<h1 align="center">DeepSeek Harness Portable</h1>

<p align="center"><strong>一个 ZIP 即可在 Windows 运行 DeepSeek Harness——无需 Node.js、安装程序或管理员权限。</strong></p>

<p align="center">
  <a href="https://github.com/maiziman/deepseek-harness-portable/releases"><strong>下载版本（包含预览版）</strong></a>
  · <a href="README.md">English</a>
  · <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a>
</p>

<p align="center">
  <a href="https://github.com/maiziman/deepseek-harness-portable/actions"><img alt="Windows 验证矩阵" src="https://img.shields.io/github/actions/workflow/status/maiziman/deepseek-harness-portable/portable-verify.yml?branch=main&amp;label=verified%20on%20Windows"></a>
  <a href="https://github.com/maiziman/deepseek-harness-portable/releases"><img alt="最新版本" src="https://img.shields.io/github/v/release/maiziman/deepseek-harness-portable?include_prereleases"></a>
  <a href="LICENSE"><img alt="MIT 许可证" src="https://img.shields.io/github/license/maiziman/deepseek-harness-portable"></a>
  <img alt="Windows x64" src="https://img.shields.io/badge/Windows-10%2F11%20x64-0078d4?logo=windows11">
  <a href="https://github.com/maiziman/deepseek-harness-portable/releases"><img alt="累计下载" src="https://img.shields.io/github/downloads/maiziman/deepseek-harness-portable/total"></a>
</p>

> [!NOTE]
> 这是由社区维护的便携打包项目。应用本身由 DeepSeek AI 开发，DeepSeek Harness 上游仓库仍是产品源码的唯一来源。

## 三步开始使用

1. 从 [Releases 页面](https://github.com/maiziman/deepseek-harness-portable/releases) 下载 `DeepSeek-Harness-win64-v<版本>.zip`，有预览版时也会列在这里（约 255 MiB）。
2. 解压到较短的路径，例如 `C:\Tools\DeepSeek-Harness`。
3. 双击 `DeepSeek-Harness.exe`，确认预览版声明，按提示填写 DeepSeek API Key，选择工作区并新建会话。

安装包不附带 API Key。社区构建的桌面壳尚未做代码签名，因此 Windows SmartScreen 可能提示“无法识别的应用”；请先核对 Release 校验和，再选择**更多信息 → 仍要运行**。

<p align="center">
  <img src="docs/product-overview.png" alt="DeepSeek Harness Portable 桌面界面" width="100%">
</p>

## 为什么选择便携版？

| | 你会得到什么 |
|---|---|
| **零环境要求** | 已包含官方 Node.js 运行时和全部生产依赖；无需 Node.js、npm、WebView2、注册表修改或管理员权限。 |
| **独立桌面窗口** | Electron 壳在原生窗口中打开 DeepSeek Harness；关闭窗口会同时停止本地服务。 |
| **真正便携** | 设置、会话、插件和日志都在程序旁的 `dsh-home` 中；整个文件夹可一起移动和备份。 |
| **发布可验证** | Node.js 下载会与官方 SHA256 文件核对；每个包记录精确组件版本，并随 Release 提供校验和。 |
| **全新系统验证** | 每次推送都在全新的 Windows Server 2022 和 2025 GitHub runner 上完成构建与真实启动。 |
| **自动跟进官方版本** | 每六小时检查一次官方 dsh 版本；只有两个 Windows 任务和暂存的 Release 附件都通过验证，才会自动公开。 |
| **主动提示更新** | 桌面程序每天最多检查一次已公开的 GitHub Release，发现新版后先询问，再打开经过验证的下载页面；不会静默替换文件。 |

### 便携 ZIP 还是官方 npm 安装？

| | 便携 ZIP | 官方 npm 包 |
|---|---|---|
| 更适合 | 快速体验、非技术用户、移动硬盘/U 盘 | 开发者和统一管理 Node.js 的环境 |
| 准备工作 | 解压并双击 | 安装 Node.js 22.19+ 和 npm 包 |
| 更新方式 | 程序提示已公开的新版本；下载新 ZIP 并迁移 `dsh-home` | 通过 npm 更新 |
| 运行时 | 已内置并固定版本 | 使用电脑上的 Node.js |

## 兼容性与可信依据

- **系统：** Windows 10 21H2 或更高版本、Windows 11，x64 架构。
- **权限：** 无需管理员权限；界面和服务仅在本机运行。
- **包内内容：** 官方 Node.js 运行时、已发布的 `@deepseek-ai/dsh` 包、生产依赖和 Electron 桌面壳。
- **验证方式：** 先用 `SHA256SUMS.txt` 核对 ZIP，再运行 `verify-package.ps1` 完成真实启动和 UI 渲染探测。
- **当前成熟度：** DeepSeek Harness 0.1 仍是面向 Harness 开发者的预览版，界面、插件和 API 会持续快速演化。

完整的构建流程、版本固定、验证矩阵和发布方式见[构建与验证](docs/BUILDING.zh.md)。

## 自行构建

```powershell
# Windows 10+、PowerShell 5.1 或 7，并可访问 npm registry
.\build-portable.ps1
```

命令会生成 `dist\DeepSeek-Harness-win64-v<dsh版本>.zip` 与 `dist\SHA256SUMS.txt`。下载的 Node.js 运行时必须通过官方校验后才会进入产物。

## 常见问题

<details>
<summary><strong>我的数据保存在哪里？</strong></summary>

可执行文件旁的 `dsh-home` 保存设置、会话、插件和日志；备份或迁移时复制这个文件夹即可。工作区仍保存在你选择的原位置。

</details>

<details>
<summary><strong>如何卸载？</strong></summary>

关闭程序并删除整个文件夹即可。便携版不会创建安装项或注册表项；如需同时清理 Electron 浏览器缓存，可再删除 `%APPDATA%\DeepSeek Harness`（若存在）。

</details>

<details>
<summary><strong>能从命令行使用吗？</strong></summary>

可以。运行 `dsh.cmd web` 打开 Web UI，或用 `dsh.cmd --profile headless "任务"` 执行无界面任务。

</details>

<details>
<summary><strong>程序如何检查更新？</strong></summary>

程序每 24 小时最多检查一次本仓库已经公开的 Release。发现更高版本时，会显示当前和新版 dsh 版本，由你决定是否打开下载页。程序不会自动下载或覆盖文件；请核对 Release 校验和、关闭程序、解压新包，并保留 `dsh-home` 和 `workspace`。如需禁用检查，可在启动前设置 `DSH_UPDATE_CHECK=0`。

</details>

<details>
<summary><strong>为什么首次启动更慢？</strong></summary>

首次运行会初始化 profile，Windows 杀毒软件也可能扫描整个便携包。启动页会显示 5 个可观测阶段、累计等待时间，以及 manifest 提供总数时已经准备好的 profile 组件准确数量。进度条只在确认工作完成后推进，因此安全扫描期间可能停在当前阶段，而不会显示误导性的剩余时间；后续启动通常会更快。

</details>

## 参与贡献与获得帮助

遇到打包或兼容性问题？请[提交 Issue](https://github.com/maiziman/deepseek-harness-portable/issues/new/choose)，附上 Windows 版本、包文件名、复现步骤和已脱敏日志。提交 PR 前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；安全漏洞请按 [SECURITY.md](SECURITY.md) 私下报告。

DeepSeek Harness 本身的问题请提交到[上游 Issue](https://github.com/deepseek-ai/deepseek-harness/issues)。

## 许可与致谢

本仓库中的打包工具采用 [MIT 许可证](LICENSE)。构建产物由 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（MIT，© DeepSeek AI）、Node.js、Electron 和各自许可下的 npm 依赖组装；每个包的 `manifest.json` 会记录精确版本。
