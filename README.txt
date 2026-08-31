CedarDSH Desktop（Windows x64 便携版）
========================================
版本：构建时自动写入；也可查看 manifest.json。
系统：Windows 10 21H2 或更高版本、Windows 11，64 位。

快速开始
1. 将整个文件夹解压到较短的位置，例如 C:\Tools\CedarDSH。
2. 双击 DeepSeek-Harness.exe。
3. 添加模型提供方，选择工作区，然后开始会话。

无需 Node.js、安装程序或管理员权限。

数据与更新
- 设置、会话、插件和日志保存在 dsh-home。
- 更新时关闭程序，解压新版，并保留原来的 dsh-home 与 workspace。
- 程序只提示公开的新版本，不会静默下载或覆盖文件。
- 卸载时关闭程序并删除整个文件夹。
- 日志位于 dsh-home\logs\server.log。

可选插件
需要自动识别自定义模型的思考与图像能力时，请使用独立项目 CedarDSH Model Probe：
https://github.com/maiziman/cedardsh-model-probe

命令行（可选）
  dsh.cmd web
  dsh.cmd --profile headless "任务"

说明
CedarDSH Desktop 使用官方标签源码构建，不给上游 DeepSeek Harness 源码打补丁。
这是独立社区项目，不是 DeepSeek 官方产品或官方发布渠道。
