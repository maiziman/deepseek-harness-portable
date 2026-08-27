# DeepSeek Harness Portable（dsh 便携桌面版）

> 把 DeepSeek Harness 打包成免安装、零环境的 Windows 桌面程序——一个 ZIP，双击即用。

[English](README.md) | **中文**

[![verify](https://img.shields.io/github/actions/workflow/status/maiziman/deepseek-harness-portable/portable-verify.yml?branch=main&label=verify%20matrix)](https://github.com/maiziman/deepseek-harness-portable/actions)
[![release](https://img.shields.io/github/v/release/maiziman/deepseek-harness-portable?include_prereleases)](https://github.com/maiziman/deepseek-harness-portable/releases)
[![license](https://img.shields.io/github/license/maiziman/deepseek-harness-portable)](LICENSE)
[![platform](https://img.shields.io/badge/platform-Windows%20x64-0078d4)](#兼容性与验证)
[![downloads](https://img.shields.io/github/downloads/maiziman/deepseek-harness-portable/total)](https://github.com/maiziman/deepseek-harness-portable/releases)

<details>
<summary><b>为什么要做这个项目？</b></summary>

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）官方通过 npm 分发，
需要目标机器安装 Node.js 22.19+。如果你想把产品直接交给非技术用户，或在一台不方便安装
Node 工具链的机器上运行——本项目从 npm 最新发布的 `@deepseek-ai/dsh` 构建出**一个自包含 ZIP**：

- 内置官方 Node.js 运行时，目标机无需 Node；
- 原生桌面窗口（Electron 内嵌 UI），双击打开的是**独立程序**，不是浏览器标签页；
- 数据全部在包内，整个文件夹可拷进 U 盘随身携带、跨机器迁移。

</details>

## 快速开始

1. 从 [最新 Release](https://github.com/maiziman/deepseek-harness-portable/releases) 下载 `DeepSeek-Harness-win64-v<版本>.zip`
2. 解压（建议短路径，如 `C:\Tools\`）
3. 双击 `DeepSeek-Harness.exe` → 窗口秒开 → 内测声明点「继续」→ 设置 → 模型 → 填入 DeepSeek API Key → 选择工作目录，开始对话

![DeepSeek Harness Portable 首次启动界面](docs/screenshot.png)

## 特性

| | |
|---|---|
| 🖥️ **独立桌面程序** | Electron 内嵌 dsh 界面（自带 Chromium，不依赖系统 WebView2）；窗口立即弹出，界面就绪后自动加载 |
| 📦 **零环境要求** | 内置官方 Node.js + 全部生产依赖（约 458 个包，含 koffi / node-pty 原生模块）；无需 Node、npm、管理员权限，不写注册表 |
| 🧳 **真便携** | `dsh-home` 保存配置、会话、插件；文件夹即全部，卸载 = 删除文件夹 |
| 🔒 **可复现构建** | 版本钉死（dsh / Node / Electron 均可参数化），Node 官方 SHA256 校验，pnpm 锁定依赖，构建确定性 |
| 🧪 **验证门禁** | 包内冒烟探针 + GitHub Actions 矩阵（Windows Server 2022/2025 全新 runner）每次推送执行；打 tag 自动发布 Release |

## 工作原理

```
build-portable.ps1
 ├─ 1. 解析版本（dsh = npm 最新、Node/Electron 钉版）
 ├─ 2. Node 运行时：官方 win-x64 + SHA256 校验
 ├─ 3. pnpm 生产安装（hoisted 扁平 node_modules——无符号链接，ZIP 安全）
 ├─ 4. Electron 壳：packager → DeepSeek-Harness.exe
 ├─ 5. 组装目录（runtime/ + app/ + dsh-home/ + README.txt + dsh.cmd）
 ├─ 6. 冒烟：静默启动应用，断言服务器 URL + UI 截图，退出码 0
 └─ 7. 压缩 + SHA256SUMS.txt    ← DeepSeek-Harness-win64-v<dsh>.zip
```

桌面壳（`shell/main.js`）启动 `runtime\node.exe` 运行 `dsh web --no-open --port 0`（自动挑选空闲端口），
从服务器就绪行解析 URL 后在窗口内展示。单实例锁保证二次双击聚焦已有窗口；关闭窗口即整树退出服务。

## 从源码构建

```powershell
# 前置：Windows 10+，PowerShell 7 或 Windows PowerShell 5.1，可访问 npm registry
.\build-portable.ps1
```

| 参数 | 说明 |
|---|---|
| `-DshVersion 0.1.1-rc.2` | dsh 版本；省略则取 npm 最新版 |
| `-NodeVersion v24.19.0` | 官方 Node 版本（需满足 dsh engines `^22.19 \|\| >=24`） |
| `-ElectronVersion 44.0.0` | Electron 版本 |
| `-ElectronMirror npmmirror` | Electron 二进制源：`npmmirror`（国内默认）/ `github`（CI）/ 自定义镜像 URL |
| `-SkipSmoke` | 跳过冒烟；`-ForceDownloadNode` 强制重新下载 Node 并校验 |

产物：`dist\DeepSeek-Harness-win64-v<dsh版本>.zip` + `dist\SHA256SUMS.txt`；包内 `manifest.json`
记录全部版本与关键文件 SHA256。

## 兼容性与验证

`verify-package.ps1` 是统一的兼容性探针——确定性通过/失败，随处可跑：

```powershell
.\verify-package.ps1                  # 验证 dist\ 最新 ZIP
.\verify-package.ps1 -ZipPath x.zip   # 验证指定包
```

断言：解压完整性 → manifest/Node 版本一致 → 真实启动（服务器就绪、URL 输出、UI 渲染、截图、退出码 0）
→ 首次启动 profile 自动初始化。

| 层级 | 覆盖 | 频率 |
|---|---|---|
| 构建内冒烟 | 以上全部（单机） | 每次构建 |
| GitHub Actions 矩阵（`windows-2022` + `windows-2025` 全新机器） | 构建 + 验证 + 产物 | 每次 push 与 `v*` tag |
| 真机 / Windows Sandbox | 消费版 Win10/11、杀软、老硬件 | 每版抽样 1-2 台 |

> GitHub runner 为 Server 镜像；消费版 Win10/11 的最终背书：每版在 1-2 台真机（或 Windows Sandbox）
> 跑一次同一探针。要求：Windows 10 21H2+、x64、无需管理员；极少数精简系统如遇程序无法启动，
> 安装 VC++ 2022 x64 运行库。

## 常见问题

- **首次启动 SmartScreen 提示？** → 「更多信息」→「仍要运行」。包内 `node.exe` 为 Node.js 官方签名二进制；校验和见包内 `manifest.json` 与 Release 的 SHA256SUMS。
- **端口被占用？** → 应用自动挑选空闲端口；命令行可用 `dsh.cmd web --port 8080`。
- **数据在哪？** → exe 旁边的 `dsh-home` 文件夹；备份/迁移即拷贝该文件夹。
- **能命令行用吗？** → `dsh.cmd web`、`dsh.cmd --profile headless "任务"` 等。
- **首次启动为什么慢？** → 首次需初始化 profile 与符号链接回退、且被杀软全量扫描；之后启动只需数秒。

## 目录结构

```
.
├─ build-portable.ps1     主构建（运行时/安装/打包/组装/冒烟/压缩）
├─ verify-package.ps1     兼容性探针（解压/版本/冒烟/首启自检）
├─ watch-progress.ps1     开发辅助：每 20 秒一行进度
├─ shell/                 Electron 壳源码（main.js、图标生成器）
├─ .github/workflows/     CI 矩阵 + tag 自动发布
├─ docs/                  README 截图
└─ dist/ .build/ .cache/  构建产物（git 忽略；正式包走 Release）
```

## 参与贡献

欢迎 Issue 和 PR。发布新版：更新钉版默认值（或传参）→ 本地 `.\build-portable.ps1` →
CI 矩阵全绿后打 `v*` tag 自动发布。

## 许可与致谢

本项目 **MIT**（[LICENSE](LICENSE)），仅含构建工具链，不含 DeepSeek Harness 源码。
打包产物由以下软件组装，版权归各自所有者：

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（MIT，© DeepSeek AI）
- Node.js（MIT）· Electron（MIT）· `app\node_modules` 内全部 npm 依赖（各自许可，版本见 `manifest.json`）
