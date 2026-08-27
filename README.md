# DeepSeek Harness Portable（dsh 便携桌面版构建工具）

把 DeepSeek Harness 的最新 npm 发行版，一键打包成**免安装、跨机器可用的 Windows 桌面程序 ZIP**。

```
DeepSeek-Harness.zip  → 解压 → 双击 DeepSeek-Harness.exe → 独立桌面窗口（非浏览器）
```

English summary is at the bottom.

## 特性

- **独立桌面窗口**：Electron 内嵌 dsh Web UI（自带 Chromium，不依赖系统 WebView2）；双击秒开“正在启动…”窗口，界面就绪自动跳转
- **零环境要求**：内置官方 Node.js 运行时 + dsh 生产依赖（458 包，含 koffi/node-pty 原生模块）；目标机无需 Node/npm/管理员权限
- **真便携**：配置、会话、插件全部保存在包内 `dsh-home`，整个文件夹可拷走/U 盘携带；卸载 = 删文件夹
- **可复现构建**：版本钉死（dsh / Node / Electron 均可参数化），Node 官方 SHA256 校验，pnpm 锁定依赖，构建+冒烟+压缩全自动
- **兼容性门禁**：内置冒烟探针 + GitHub Actions 矩阵（windows-2022 / windows-2025 全新 runner），打 tag 自动出 GitHub Release 附件

## 构建

```powershell
# 前置：Windows 10+，PowerShell 7 或 Windows PowerShell 5.1，可访问 npm registry
.\build-portable.ps1
```

常用参数：

| 参数 | 说明 |
|---|---|
| `-DshVersion 0.1.1-rc.2` | dsh 版本；省略则取 npm 最新版 |
| `-NodeVersion v24.19.0` | 官方 Node 版本（需匹配 dsh engines `^22.19 \|\| >=24`） |
| `-ElectronVersion 44.0.0` | Electron 版本 |
| `-ElectronMirror npmmirror` | Electron 二进制源：`npmmirror`（国内默认）/ `github`（CI）/ 自定义镜像 URL |
| `-SkipSmoke` | 跳过冒烟；`-ForceDownloadNode` 强制重新下载 Node 并校验 |

产物：`dist\DeepSeek-Harness-win64-v<dsh 版本>.zip` + `dist\SHA256SUMS.txt`，包内 `manifest.json` 记录全部版本与校验和。

## 验证（兼容性探针）

```powershell
.\verify-package.ps1                 # 验证 dist\ 最新 ZIP（4 步：解压/版本/冒烟/首次启动自检）
.\verify-package.ps1 -ZipPath x.zip  # 指定包
```

- **本机**：直接运行。Windows 10/11 专业版可用 Windows Sandbox 或 VM 做“全新系统”验证
- **CI 矩阵**：`.github\workflows\portable-verify.yml`，push 与 tag 自动执行；打 `v*` tag 自动发布 Release 附件
- **边界**：GitHub runner 是 Server 镜像；Win10/11 消费版最终背书：每版在 1-2 台真机或沙盒跑一次探针

## 目录结构

```
portable-desktop\
├─ build-portable.ps1     主构建脚本（运行时准备/依赖安装/打包/组装/冒烟/压缩）
├─ verify-package.ps1     兼容性探针（解压/版本/冒烟/首启自检）
├─ watch-progress.ps1     开发辅助：每 20s 写一行构建进度
├─ shell\                 Electron 壳源码
│  ├─ main.js              桌面壳（秒开窗口/服务托管/单实例/退出清理/截图自检）
│  ├─ package.json
│  └─ make-icon.ps1        生成应用图标
├─ workflow\              GitHub Actions 矩阵 workflow（复制用）
├─ README.txt             打进 ZIP 的中文使用说明
├─ dsh.cmd                打进 ZIP 的 CLI 入口
├─ dist\                   构建产物（git 忽略，走 Release）
└─ .build\ .cache\         中间产物（git 忽略）
```

## 许可与致谢

本项目 MIT（见 [LICENSE](LICENSE)），仅包含构建工具链，不含 DeepSeek Harness 源码。

打包产物由以下软件组装，版权归各自所有者：

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（MIT，DeepSeek AI）
- Node.js（MIT）
- Electron（MIT）
- 及 `app\node_modules` 内全部 npm 依赖（各自许可，随包分发，`manifest.json` 记录版本）

---

## English (brief)

This repository builds DeepSeek Harness into a portable, zero-install Windows x64 desktop app ZIP:
double-click `DeepSeek-Harness.exe` for a standalone window (Electron-embedded Web UI), bundled Node.js
runtime and production dependencies; all data stays in-package. Build with `.\build-portable.ps1`
(versions parametrizable), verify with `.\verify-package.ps1`, and let the GitHub Actions matrix
(Server 2022 + 2025) gate every release on tags `v*`. MIT licensed.
