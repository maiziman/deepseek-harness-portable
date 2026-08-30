<h1 align="center">DeepSeek Harness Pure Portable</h1>

<p align="center"><strong>Official tagged DeepSeek Harness source, built without code patches, in one clean Windows desktop app.</strong></p>

<p align="center">
  <a href="https://github.com/maiziman/deepseek-harness-portable/releases/latest"><strong>Download the latest ZIP</strong></a>
  · <a href="https://github.com/maiziman/deepseek-harness-portable/releases/tag/plugin-model-capabilities-v0.1.1"><strong>Get the optional Custom API plugin</strong></a>
  · <a href="README.zh.md">中文说明</a>
</p>

<p align="center">
  <a href="https://github.com/maiziman/deepseek-harness-portable/actions"><img alt="Verification matrix" src="https://img.shields.io/github/actions/workflow/status/maiziman/deepseek-harness-portable/portable-verify.yml?branch=main&amp;label=verified%20on%20Windows"></a>
  <a href="https://github.com/maiziman/deepseek-harness-portable/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/maiziman/deepseek-harness-portable?include_prereleases"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/maiziman/deepseek-harness-portable"></a>
  <img alt="Windows x64" src="https://img.shields.io/badge/Windows-10%2F11%20x64-0078d4?logo=windows11">
  <a href="https://github.com/maiziman/deepseek-harness-portable/releases"><img alt="Total downloads" src="https://img.shields.io/github/downloads/maiziman/deepseek-harness-portable/total"></a>
</p>

| Trust point | What it means |
|---|---|
| **Upstream stays upstream** | The selected official `dsh-v*` tag is built without source edits through its own `release:verify`, `build:official`, and `release:pack` process. |
| **Only the Windows experience is added** | The project supplies pinned Node.js, pnpm, and Electron components, an independent window, a portable data directory, and an explicit update prompt. |
| **No hidden capability layer** | The default ZIP does not bundle or automatically install any capability plugin. Optional plugins have separate packages, checksums, and Releases. |

> [!IMPORTANT]
> This is an independent community packaging project. It is not affiliated with, endorsed by, sponsored by, or an official release channel of DeepSeek. “DeepSeek Harness” and the whale logo identify the packaged upstream software and remain DeepSeek trademarks and brand assets.

<p align="center">
  <img src="docs/social-preview.png" alt="DeepSeek Harness Pure Portable — official tagged source without code patches in a portable Windows desktop app" width="100%">
</p>

## Get started in three steps

1. Download `DeepSeek-Harness-win64-v<version>.zip` from [Releases](https://github.com/maiziman/deepseek-harness-portable/releases), including preview versions when available.
2. Extract the ZIP to a short path such as `C:\Tools\DeepSeek-Harness`.
3. Double-click `DeepSeek-Harness.exe`, accept the preview notice, add a DeepSeek API key when prompted, choose a workspace, and start a session.

No Node.js, installer, or administrator access is required. No API key is bundled. Windows SmartScreen may show an unrecognized-app warning because the community-built desktop shell is not code-signed; verify the Release checksum before choosing **More info → Run anyway**.

<p align="center">
  <img src="docs/product-overview.png" alt="DeepSeek Harness Pure Portable desktop interface" width="100%">
</p>

## What the portable app adds

| | What it gives you |
|---|---|
| **Zero setup** | The Node.js runtime, production dependencies, and a hash-pinned pnpm used only by optional official plugin commands are included. No WebView2, registry changes, or administrator access is required. |
| **A dedicated desktop window** | The Electron shell opens upstream DeepSeek Harness in its own window and stops the local server when the window closes. |
| **Portable data** | Settings, sessions, manually installed plugins, and logs stay under `dsh-home` beside the app. Move or back up the folder as one unit. |
| **Verifiable releases** | Node.js downloads are checked against official SHA256 files; the manifest records exact component and upstream source identities; each Release includes checksums. |
| **Clean-machine testing** | Every push builds and boots on fresh Windows Server 2022 and 2025 GitHub runners before artifacts are published. |
| **Automatic upstream tracking** | Every six hours, the release workflow checks the highest official `dsh-v*` tag, builds that exact commit with the upstream release process, and publishes the next verified portable version when needed. It does not wait for an npm publication. |
| **Update awareness** | The app checks published portable Releases at most once a day and asks before opening the verified download page. It never replaces files silently. |

### Portable ZIP or the official npm install?

| | Pure Portable ZIP | Official npm package |
|---|---|---|
| Best for | Trying the app, non-technical users, removable drives | Developers and managed Node.js environments |
| Setup | Extract and double-click | Install a supported Node.js version and the npm package |
| Updates | The app reports published updates; download the new ZIP and keep `dsh-home` | Update through npm |
| Runtime | Bundled and pinned | Uses the machine's Node.js installation |
| Plugins | None installed by default | None added by this project |

## Optional: DSH Custom API Capabilities

[`DSH Custom API Capabilities`](plugins/dsh-model-capabilities/README.md) is a separate, opt-in Bundle for OpenAI-compatible custom models. It detects supported reasoning levels and image input, preserves every explicit model setting, and does not make active inference requests to public endpoints by default.

Download the independently versioned package and checksum from the [DSH Custom API Capabilities v0.1.1 Release](https://github.com/maiziman/deepseek-harness-portable/releases/tag/plugin-model-capabilities-v0.1.1). Installing or updating a portable ZIP never installs this plugin for you.

## Compatibility and verification

- **System:** Windows 10 21H2 or newer, Windows 11, x64 architecture.
- **Permissions:** no administrator access; the UI and its server stay on the local machine.
- **Upstream input:** either a published `@deepseek-ai/dsh` package for local builds or the complete package set produced from an exact official Git tag by upstream release scripts.
- **Package contents:** the verified DeepSeek Harness production tree, official Node.js runtime, hash-pinned pnpm for explicit plugin management, Electron desktop shell, portable directories, notices, and launchers; no capability plugin is bundled.
- **Build-path privacy:** packaging changes no executable upstream code or runtime configuration. It makes generated, non-executable source-region and package-manager shim comments repository-relative, then scans every packaged file for the actual repository, runner, temporary, package-input, and user-home paths before creating the ZIP.
- **Verification:** compare the downloaded ZIP with `SHA256SUMS.txt`, then run `verify-package.ps1` for a real boot and UI-render probe.
- **Current maturity:** DeepSeek Harness 0.1 is a preview for Harness developers; its UI, plugin APIs, and package layout can change quickly.

See [Building and verification](docs/BUILDING.md) for the source provenance checks, build inputs, Windows matrix, and release process.

## Build it yourself

```powershell
# Windows 10+, PowerShell 7.2+, and access to the npm registry
.\build-portable.ps1
```

Without an official package directory, the command builds from a published npm version and produces `dist\DeepSeek-Harness-win64-v<portable-version>.zip` plus `dist\SHA256SUMS.txt`. `manifest.json` records the portable version separately from the packaged dsh version and exact source provenance when supplied.

## FAQ

<details>
<summary><strong>Where is my data?</strong></summary>

The `dsh-home` folder beside the executable contains settings, sessions, manually installed plugins, and logs. Copy that folder to back up or migrate your data. Workspaces stay wherever you selected them.

</details>

<details>
<summary><strong>How do I uninstall it?</strong></summary>

Close the app and delete its folder. The portable build creates no installer or registry entry. To remove Electron's browser cache as well, delete `%APPDATA%\DeepSeek Harness Pure Portable` if it exists.

</details>

<details>
<summary><strong>Can I use the command line?</strong></summary>

Yes. Run `dsh.cmd web` for the Web UI or `dsh.cmd --profile headless "task"` for a headless task. The shim starts the packaged official CLI directly. Install a downloaded Bundle explicitly with `dsh.cmd plugin --profile <profile> add <plugin.tgz> --offline`.

</details>

<details>
<summary><strong>How do updates work?</strong></summary>

The app checks this repository's complete published portable Releases at most once every 24 hours. A newer version produces an opt-in prompt with the current and new portable versions. It does not download or replace files; verify the checksum, close the app, extract the new package, and preserve `dsh-home` and `workspace`. Set `DSH_UPDATE_CHECK=0` before launch to disable the check.

</details>

<details>
<summary><strong>Why can the first launch take longer?</strong></summary>

The first run initializes the profile and Windows antivirus software may scan the full portable package. The startup page shows observed milestones, elapsed time, and the exact number of prepared profile components when the package manifest provides that total. The bar advances only when work is observed as complete, so it may pause during security scanning instead of displaying a misleading estimate. Later launches are usually faster.

</details>

## Contributing and support

Found a packaging bug or compatibility problem? [Open an issue](https://github.com/maiziman/deepseek-harness-portable/issues/new/choose) with your Windows version, package filename, reproduction steps, and sanitized logs. See [CONTRIBUTING.md](CONTRIBUTING.md) before sending a pull request and [SECURITY.md](SECURITY.md) for private vulnerability reporting.

Problems in DeepSeek Harness itself belong in the [upstream issue tracker](https://github.com/deepseek-ai/deepseek-harness/issues).

## License and attribution

The packaging tools in this repository are available under the [MIT License](LICENSE). Built ZIPs are assembled from [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (MIT, © DeepSeek AI), Node.js, Electron, and npm dependencies under their respective licenses. Exact versions and source provenance are recorded in each package's `manifest.json`. The whale mark is reproduced from the upstream favicon only to identify the packaged upstream software; its inclusion does not imply DeepSeek endorsement or authorization. See [Third-party notices](THIRD_PARTY_NOTICES.md) for its source and license notice.
