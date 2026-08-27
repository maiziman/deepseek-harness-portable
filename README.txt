DeepSeek Harness 便携桌面版（Windows x64）
==========================================
版本：构建时自动写入；也可查看 manifest.json。
系统要求：Windows 10 21H2 及以上（64 位）。
无需安装 Node.js、npm 或任何其他运行环境，无需管理员权限。

一、快速开始
1. 将整个 DeepSeek-Harness 文件夹解压到任意位置。
   （建议短路径，例如 C:\Tools\DeepSeek-Harness）
2. 双击 DeepSeek-Harness.exe 启动桌面程序。
3. 首次使用：在程序里打开「设置 → 模型」，填入 DeepSeek API Key 并保存。
4. 在「设置 → 工作区」选择项目目录后即可开始对话。

二、数据与便携
- 配置、会话历史、插件全部保存在包内 dsh-home 目录，随文件夹一起走。
- 换电脑或备份：直接拷贝整个文件夹即可，进度和配置不丢。
- 卸载：直接删除整个文件夹。不写注册表，不残留任何系统文件。
- 服务器日志：dsh-home\logs\server.log。

三、更新
- 程序每 24 小时最多检查一次已公开的 GitHub Release。
- 发现新版时会先询问，再打开下载页面；不会静默下载或覆盖程序。
- 更新前请核对 Release 中的 SHA256，关闭程序并保留 dsh-home 与 workspace。
- 如需禁用检查，请在启动前设置环境变量 DSH_UPDATE_CHECK=0。

四、命令行用法（可选）
在文件夹内打开 cmd 后运行：
  dsh.cmd web --port 8080        以指定端口启动（默认自动挑空闲端口）
  dsh.cmd --profile headless "任务"   运行一个一次性任务并退出

五、常见问题
- Windows SmartScreen 拦截：点「更多信息」→「仍要运行」。
  （程序内含 Node.js 官方签名的 node.exe；本包校验和见 manifest.json）
- 提示缺少系统 DLL：安装微软 VC++ 运行库（x64，2022 版）。
- 端口占用：程序会自动选择空闲端口，无需手动处理。
- 首次启动较慢：启动页按真实阶段显示进度、组件完成数和累计等待时间；安全软件扫描期间可能暂时停在当前阶段。
- 断网可用：本地界面无需联网；更新检查失败不会阻止启动，模型调用仍需联网。

六、构建信息
本包由 portable-desktop\build-portable.ps1 构建；
manifest.json 记录了 dsh / Node / Electron 版本与关键文件 SHA256。
