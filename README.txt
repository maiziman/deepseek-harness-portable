DeepSeek Harness 纯净便携桌面版（Windows x64）
================================================
版本：构建时自动写入；也可查看 manifest.json。
系统要求：Windows 10 21H2 及以上（64 位）。
无需安装 Node.js、npm 或其他运行环境，无需管理员权限。

纯净说明：包内 DeepSeek Harness 来自精确的官方 dsh-v* 标签或已发布 npm 包；官方标签构建不修改上游可执行代码或运行配置，并使用上游自己的 release:verify、build:official 与 release:pack 流程。官方源码任务会生成唯一的 Windows 运行 lock，Windows 构建逐项核对内部与外部依赖和依赖关系后，以 frozen、offline 方式安装。打包时只把构建工具生成的非执行源码分区与 shim 注释改成仓库相对形式，并扫描全部成品文件，拒绝真实构建机路径。便携项目增加固定版本的 Windows Node.js、pnpm 与 Electron 环境、独立窗口、便携数据目录和明确的更新提示。默认 ZIP 不内置、也不会自动安装任何能力插件。

声明：这是独立的社区便携打包项目，与 DeepSeek 无隶属、合作、赞助或官方授权关系，也不是官方发布渠道。“DeepSeek Harness”名称和鲸鱼 LOGO 仅用于标识所打包的上游软件，其商标与品牌资产归 DeepSeek 所有。

一、快速开始
1. 将整个 DeepSeek-Harness 文件夹解压到任意位置。
   建议使用短路径，例如 C:\Tools\DeepSeek-Harness。
2. 双击 DeepSeek-Harness.exe 启动桌面程序。
3. 首次使用时，在程序里打开「设置 → 模型」，填入 DeepSeek API Key 并保存。
4. 在「设置 → 工作区」选择项目目录后即可开始对话。

二、数据与便携
- 设置、会话历史、手动安装的插件和日志保存在包内 dsh-home 目录。
- 换电脑或备份时，关闭程序后复制整个文件夹即可；工作区仍在你选择的原位置。
- 卸载时关闭程序并删除整个文件夹；便携版不创建安装项或注册表项。
- 如需同时清理 Electron 浏览器缓存，可删除 %APPDATA%\DeepSeek Harness Pure Portable（若存在）。
- 服务器日志位于 dsh-home\logs\server.log。

三、更新
- 程序每 24 小时最多检查一次完整公开的便携版 GitHub Release。
- 发现新版时会先询问，再打开下载页面；不会静默下载或覆盖程序。
- 更新前请核对 Release 中的 SHA256，关闭程序并保留 dsh-home 与 workspace。
- 如需禁用检查，请在启动前设置环境变量 DSH_UPDATE_CHECK=0。

四、可选插件
默认 ZIP 不含插件。DSH 自定义 API 能力识别插件可识别 OpenAI-compatible 自定义模型的思考等级与图像输入能力，始终保留明确设置，默认不对公网端点发起主动推理请求。
安装包、校验和与说明：
https://github.com/maiziman/deepseek-harness-portable/releases/tag/plugin-model-capabilities-v0.1.1

五、命令行用法（可选）
在文件夹内打开 cmd 后运行：
  dsh.cmd web --port 8080             以指定端口启动（默认自动选择空闲端口）
  dsh.cmd --profile headless "任务"    运行一次任务并退出
命令行入口直接运行包内官方 CLI。需要插件时，请明确执行：
  dsh.cmd plugin --profile <profile> add <插件.tgz> --offline

六、常见问题
- Windows SmartScreen 拦截：先核对 Release 校验和，再点「更多信息」→「仍要运行」。
- 提示缺少系统 DLL：安装微软 VC++ 运行库（x64，2022 版）。
- 端口占用：程序会自动选择空闲端口，无需手动处理。
- 首次启动较慢：启动页按真实阶段显示进度、组件完成数和累计等待时间；安全软件扫描期间可能暂时停在当前阶段。
- 断网可用：本地界面无需联网；更新检查失败不会阻止启动，模型调用仍取决于所选端点。

七、构建信息
本包由 portable-desktop\build-portable.ps1 构建。manifest.json 分别记录便携版本、dsh / Node.js / pnpm / Electron 版本、上游源码来源（若提供）与关键文件 SHA256。
