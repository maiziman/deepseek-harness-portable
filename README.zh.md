<h1 align="center">CedarDSH Desktop</h1>

<p align="center"><strong>DeepSeek Harness Windows 桌面版：下载一个 ZIP，解压就能运行。</strong></p>

<p align="center">
  <a href="https://github.com/maiziman/cedardsh-desktop/releases/latest"><strong>下载 Windows 版</strong></a>
  · <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/maiziman/cedardsh-desktop/actions"><img alt="Windows 验证" src="https://img.shields.io/github/actions/workflow/status/maiziman/cedardsh-desktop/portable-verify.yml?branch=main&amp;label=Windows%20verified"></a>
  <a href="https://github.com/maiziman/cedardsh-desktop/releases"><img alt="最新版本" src="https://img.shields.io/github/v/release/maiziman/cedardsh-desktop?include_prereleases"></a>
  <a href="LICENSE"><img alt="MIT 许可证" src="https://img.shields.io/github/license/maiziman/cedardsh-desktop"></a>
  <img alt="Windows x64" src="https://img.shields.io/badge/Windows-10%2F11%20x64-0078d4?logo=windows11">
</p>

<p align="center">
  <img src="docs/social-preview.png" alt="CedarDSH Desktop：DeepSeek Harness Windows 纯净便携版" width="100%">
</p>

## 三步开始使用

1. 从 [Releases](https://github.com/maiziman/cedardsh-desktop/releases/latest) 下载 `CedarDSH-Desktop-win64-v<版本>.zip`。
2. 将整个 ZIP 解压到较短的路径，例如 `C:\Tools\CedarDSH`。
3. 双击 `CedarDSH-Desktop.exe`，添加模型提供方、选择工作区，然后开始会话。

无需安装 Node.js，无需安装程序，也无需管理员权限。社区构建尚未进行代码签名，Windows SmartScreen 可能提示“无法识别的应用”；请先用 `SHA256SUMS.txt` 核对 ZIP，再选择**更多信息 → 仍要运行**。

<p align="center">
  <img src="docs/product-overview.png" alt="CedarDSH Desktop 界面" width="100%">
</p>

## 它提供什么

- **一个便携文件夹：** 程序、运行环境、设置、会话、插件和日志都放在一起。
- **正常的桌面窗口：** 关闭窗口时，本地 DeepSeek Harness 服务也会停止。
- **官方标签源码：** 使用上游自己的发布流程构建，不给 DeepSeek Harness 源码打补丁。
- **一键更新：** 点击“设置”右侧的**更新**，即可下载、校验并安装基于 DeepSeek Harness 官方版本构建的最新程序。
- **清楚的版本信息：** 在“设置 → 关于”中查看桌面版本、官方 DSH 版本、构建时间和上次检查时间。
- **全新 Windows 验证：** 每个版本公开前都会在 Windows Server 2022 和 2025 上完成构建与真实启动。

用户数据位于 EXE 旁边的 `dsh-home`。更新器只替换程序自己的文件，不会替换 `dsh-home`、`workspace`，也不会处理你放在程序旁边的其他文件。

> [!IMPORTANT]
> CedarDSH Desktop 是独立社区项目，不是 DeepSeek 官方产品或官方发布渠道。“DeepSeek Harness”名称与鲸鱼标识仅用于说明所打包的上游软件。

## 可选：自动识别模型能力

如果自定义 OpenAI-compatible 模型没有正确声明思考或图像能力，可以安装独立项目 [CedarDSH Model Probe](https://github.com/maiziman/cedardsh-model-probe)。桌面 ZIP 默认不包含该插件。

## 常见问题

- **如何卸载：** 关闭程序并删除整个文件夹；不会留下安装项或注册表项。
- **如何备份：** 复制 `dsh-home`；工作区仍保存在你原来选择的位置。
- **为什么首次启动较慢：** 启动页会显示真实完成阶段，Windows 安全软件扫描期间可能停留一会儿；以后启动通常更快。
- **更新是否自动执行：** 不会静默更新。点击“设置”右侧的**更新**，确认版本后才会下载；ZIP 通过 GitHub 公布的 SHA-256 校验后，程序才会重启安装。下载支持断点续传：中途关闭进度窗口或退出程序，已下载的部分会保留，下次更新会从上次的进度继续。
- **如何反馈问题：** 在“设置 → 关于”中点击**复制诊断信息**，再粘贴到 GitHub Issue。复制内容不包含日志正文、API 密钥或访问令牌。
- **命令行使用：** `dsh.cmd web` 打开 Web UI；`dsh.cmd --profile headless "任务"` 执行一次无界面任务。

## 构建与验证

在 Windows 10 或更高版本、PowerShell 7.2 或更高版本中运行 `./build-portable.ps1`。构建会生成 ZIP 和 `SHA256SUMS.txt`；`manifest.json` 会记录 CedarDSH Desktop 版本、包内 DSH 版本、上游源码标签与提交以及运行时哈希。

源码来源和发布验证见[构建与验证](docs/BUILDING.zh.md)。打包问题请在本项目[提交 Issue](https://github.com/maiziman/cedardsh-desktop/issues)；DeepSeek Harness 本身的问题请提交到[上游项目](https://github.com/deepseek-ai/deepseek-harness/issues)。

## 许可证

CedarDSH Desktop 打包工具使用 [MIT 许可证](LICENSE)。成品 ZIP 内的 DeepSeek Harness、Node.js、Electron 和 npm 依赖分别遵循各自许可证，详见[第三方声明](THIRD_PARTY_NOTICES.md)。
