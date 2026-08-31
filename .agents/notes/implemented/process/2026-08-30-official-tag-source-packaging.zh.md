# Agent Note: 便携版使用官方标签源码包

Status: implemented

[English](2026-08-30-official-tag-source-packaging.md) | 中文

## 问题

DeepSeek Harness 可能先发布官方 `dsh-v*` Git 标签，之后才在 npm 提供相同版本。把 npm 作为便携版构建门槛，会推迟已经可以精确识别的官方版本，也会让自动更新承诺依赖第二个发布渠道。直接复制构建后的工作区并不等价：workspace 链接、未发布的 peer 和构建机路径都可能进入便携目录。

## 决策

每个自动便携版都从官方 `deepseek-ai/deepseek-harness` 仓库中语义版本最高的 `dsh-v*` 标签及其精确 40 位 commit 开始。只有读取权限的 Ubuntu job 会以完整标签历史 checkout 该 commit，核对根版本、CLI 版本与源码声明的 pnpm 版本，再运行该标签自身的 `release:verify`、`build:official`、`release:pack` 和 `release:verify-packed-install` 命令。它按照上游发布工作流打包 dsh family、vendor framework family 与 Landlock entry，且始终没有仓库写入权限。

这个 job 会生成一份包含全部官方 tarball、`provenance.json` 与 `SHA256SUMS.txt` 的 artifact。来源记录会绑定官方仓库、标签、commit、dsh 版本、包管理器，以及每个压缩包的包身份、字节大小与 SHA256。暂存步骤和两个 Windows 使用方都会读取归档内的 `package/package.json`，拒绝重复或意外包名、残留 `workspace:` 依赖协议，要求存在唯一且精确的 `@deepseek-ai/dsh` 入口，要求全部 dsh family 版本与标签一致，并重新计算完整文件集合和哈希。Windows Server 2022 与 2025 构建下载同一代 artifact。

源码任务会把每个已打包 manifest 声明的 repository directory 映射到官方 lockfile 中对应的 importer，验证该 importer 的源码包身份，再从 `@deepseek-ai/dsh` 开始遍历生产依赖、可选依赖与必需 peer。只有当某个未暂存的可选内部包在源码 manifest 中明确排除 Windows x64 时，任务才会将它排除。每个选中的内部包都会成为本地 consumer root 与 override；外部精确版本和指定父依赖的 override 均来自官方 lock，而不是重新向 registry 解析。任务会在线生成唯一的规范 consumer manifest、workspace policy 与 lockfile，归一化已经证明不兼容 Windows 的可选项，再逐项核对内部与外部 package 元数据、registry 解析记录和运行 snapshot。package 模型覆盖 bundled dependency、CPU、操作系统与 libc 规则、deprecated、engines、是否存在可执行入口、包身份、peer 声明与 peer 元数据；snapshot 模型覆盖依赖边、id、optional 标记、可选依赖边与传递 peer。另一套 consumer 控制模型覆盖 lockfile 版本、根 importer 的 specifier 与解析版本、根 settings、全部 override 和每个 patched dependency 的内容哈希。未知 package、snapshot、importer、setting、override、patch 或 lock 根字段会直接失败。

Schema 4 来源记录会保存这套内部包集合、规范运行 package 与 snapshot 模型及其 SHA256、consumer 控制模型及其 SHA256、Windows 可选排除项、必需 peer pin，以及三份 consumer 文件各自的字节大小和 SHA256。每个 Windows 构建都会把完整输入复制到可丢弃的 scratch 目录，重新执行压缩包、来源记录、consumer 文件、依赖图与 lock 校验，先从官方 npm registry 对 frozen lock 取齐内容，再把同一个 lock 以 frozen、offline 方式安装成 hoisted 目录树。只有规范 lock 的完整文件哈希和语义模型都验证通过后，才会启用 pnpm 的 trusted-lock 选项，避免它的默认发布时间策略在 offline 阶段访问电脑级 registry。组装前会删除包管理器清单与构建机 `file:` 路径。pnpm 包按精确版本与压缩包 SHA256 固定。包管理器安装状态只留在可丢弃的 `.build` 与临时 scratch 目录；只有经过 SHA256 验证的 pnpm 下载缓存可以保留在仓库 `.cache` 中，该压缩包不会进入成品。只有一份干净 pnpm 运行载荷和直接 shim 进入成品，专门避免用户明确执行官方 `dsh plugin` 命令时退回 Corepack 或全局包管理器。

上游构建产物可能在非执行 CSS 源码分区注释和 pnpm shim 目标注释中保留绝对 checkout 路径。便携组装会把源码标签改成仓库相对的 `packages/...` 身份，并移除 shim 注释；可执行文本、运行配置和上游行为均不改变。专门的负例测试会拒绝任何残余的这两类注释。压缩前还会执行二进制安全的全目录扫描，拒绝真实仓库、scratch、包输入、runner 与临时目录以原始、斜杠归一化、转义、URI、UTF-8 或 UTF-16 形式出现在任何文件中。

最终 manifest 会记录官方来源仓库、标签、commit、包管理器版本、完整包与运行包数量、外部 snapshot 数量、来源记录哈希、官方源码 lock 哈希、规范 consumer lock 哈希和运行模型哈希。包验证会要求 ZIP 只有一个顶层目录、启动前不存在 reparse point、`dsh-home` 为空、没有默认插件或包管理器状态，并通过内置 Node.js 驱动已安装 CLI，要求 `--version` 与所选 dsh 版本完全一致。公开前还会重新确认官方标签没有移动、自动运行的目标仍是最高标签，并且便携版本分配没有变化。这个源码选择与 [精确 ID Release 公开决策](2026-08-30-exact-id-release-publication.zh.md) 配合；后者继续负责 Draft 隔离、附件身份和从私有到公开的转换。

默认产品是 CedarDSH Desktop。它不对官方标签 Harness 源码打代码补丁，并增加固定版本的 Windows Node.js、pnpm 与 Electron 组件、桌面生命周期、便携数据目录和明确的更新提示；默认不包含、也不会自动安装任何能力插件。CedarDSH Model Probe 由独立仓库维护和发布。

## 考虑过的替代方案

**等待精确 npm 包。** 这种方式保持只使用已发布包的输入，但可能无限期推迟官方标签；`dsh-v0.1.2-alpha.1` 已经具备完整官方发布构建，却没有对应 npm 包。

**使用 `pnpm deploy` 或复制构建后的工作区。** deploy 结果不会物化完整 peer 与 profile 闭包；精确标签试验在启动时因缺少 vendor Cordis 包而失败。复制工作区还可能保留指向源码 checkout 的链接。

**重新实现上游打包格式。** 本地 packer 会复制发布策略，并可能偏离上游 `files`、版本改写和 prepack 行为。直接调用标签 checkout 自己的命令可以保持唯一发布定义。

**把每个 tarball 都作为根依赖。** 这种方式简单，但会包含 CLI 永远不会访问的包。从 CLI 计算内部依赖图并只物化该闭包，既保留同一套已验证来源，又能得到更小的运行目录。

**在 Windows 上再次生成 consumer lock。** 即使根版本精确固定，第二次解析仍可能把现有版本重新连接到不同依赖边、自动安装 peer，或套用电脑的 registry 策略。只在官方源码旁生成一次、哈希全部 consumer 文件，并在 Windows 逐项比较每个运行 snapshot，才能保留唯一一套依赖决定。

## 影响

官方标签无需 npm 发布就能成为便携版候选。源码构建时间集中在一个共享 Ubuntu job；具有写入权限的公开 job 永远不会执行上游代码。任何被篡改、不完整、重复、移动或版本不一致的包输入都会在 Electron 打包前失败。同一份不可变包集合会进入两个受支持的 Windows 版本；准备公开的同一个 Windows 2025 ZIP 随后还会在 Windows Server 2022 与 2025 上再次验证，证明已安装 CLI 版本与真实 Web 启动。

构建现在依赖上游发布脚本能够在对应标签运行，也依赖其声明的包管理器仍可获取。上游发布流程变化时，可复用源码打包 job 必须跟随该标签流程，不能静默退回 npm 或工作区复制。npm 输入只为本地手工构建保留，并会在 `manifest.json` 中以不同来源记录。
