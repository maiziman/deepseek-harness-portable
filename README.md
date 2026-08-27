<p align="center">
  <img src="docs/social-preview.png" alt="DeepSeek Harness Portable — a zero-install Windows desktop app" width="100%">
</p>

<h1 align="center">DeepSeek Harness Portable</h1>

<p align="center"><strong>Run DeepSeek Harness on Windows from one ZIP — no Node.js, installer, or administrator access required.</strong></p>

<p align="center">
  <a href="https://github.com/maiziman/deepseek-harness-portable/releases"><strong>Download releases, including previews</strong></a>
  · <a href="README.zh.md">中文说明</a>
  · <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a>
</p>

<p align="center">
  <a href="https://github.com/maiziman/deepseek-harness-portable/actions"><img alt="Verification matrix" src="https://img.shields.io/github/actions/workflow/status/maiziman/deepseek-harness-portable/portable-verify.yml?branch=main&amp;label=verified%20on%20Windows"></a>
  <a href="https://github.com/maiziman/deepseek-harness-portable/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/maiziman/deepseek-harness-portable?include_prereleases"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/maiziman/deepseek-harness-portable"></a>
  <img alt="Windows x64" src="https://img.shields.io/badge/Windows-10%2F11%20x64-0078d4?logo=windows11">
  <a href="https://github.com/maiziman/deepseek-harness-portable/releases"><img alt="Total downloads" src="https://img.shields.io/github/downloads/maiziman/deepseek-harness-portable/total"></a>
</p>

> [!IMPORTANT]
> This is an independent community packaging project. It is not affiliated with, endorsed by, sponsored by, or an official release channel of DeepSeek. The name “DeepSeek Harness” and the whale logo identify the packaged upstream software; they are DeepSeek trademarks and brand assets.

## Get started in three steps

1. Download `DeepSeek-Harness-win64-v<version>.zip` from the [Releases page](https://github.com/maiziman/deepseek-harness-portable/releases), including preview versions when available (about 255 MiB).
2. Extract the ZIP to a short path such as `C:\Tools\DeepSeek-Harness`.
3. Double-click `DeepSeek-Harness.exe`, accept the preview notice, add a DeepSeek API key when prompted, choose a workspace, and start a session.

No API key is bundled. Windows SmartScreen may show an unrecognized-app warning because the community-built desktop shell is not code-signed; verify the Release checksum before choosing **More info → Run anyway**.

<p align="center">
  <img src="docs/product-overview.png" alt="DeepSeek Harness Portable desktop interface" width="100%">
</p>

## Why use the portable build?

| | What it gives you |
|---|---|
| **Zero setup** | The official Node.js runtime and production dependencies are already included. No Node.js, npm, WebView2, registry changes, or administrator access. |
| **A real desktop app** | The Electron shell opens DeepSeek Harness in its own native window and stops the local server when the window closes. |
| **Portable by design** | Settings, sessions, plugins, and logs stay under `dsh-home` beside the app. Move or back up the folder as one unit. |
| **Verifiable releases** | Node.js downloads are checked against official SHA256 files; each package records exact component versions and ships with Release checksums. |
| **Clean-machine tested** | Every push builds and boots on fresh Windows Server 2022 and 2025 GitHub runners before artifacts are published. |
| **Automatic upstream releases** | Official dsh versions are checked every six hours and published automatically only after both Windows jobs and the staged Release assets pass verification. |
| **Update aware** | The desktop app checks published GitHub Releases at most once a day and prompts before opening the verified download page. It never replaces files silently. |

### Portable ZIP or the official npm install?

| | Portable ZIP | Official npm package |
|---|---|---|
| Best for | Trying the app, non-technical users, removable drives | Developers and managed Node.js environments |
| Setup | Extract and double-click | Install Node.js 22.19+ and npm package |
| Updates | The app reports published updates; download the new ZIP and carry over `dsh-home` | Update through npm |
| Runtime | Bundled and pinned | Uses the machine's Node.js installation |

## Compatibility and trust

- **System:** Windows 10 21H2 or newer, Windows 11, x64 architecture.
- **Permissions:** no administrator access; the UI and its server stay on the local machine.
- **Package contents:** official Node.js runtime, the published `@deepseek-ai/dsh` package, production dependencies, and the Electron desktop shell.
- **Verification:** compare the downloaded ZIP with `SHA256SUMS.txt`, then run `verify-package.ps1` for a real boot and UI-render probe.
- **Current maturity:** DeepSeek Harness 0.1 is a preview for Harness developers; the UI, plugins, and APIs are still evolving quickly.

See [Building and verification](docs/BUILDING.md) for the complete build pipeline, version pins, verification matrix, and release process.

## Build it yourself

```powershell
# Windows 10+, PowerShell 5.1 or 7, and access to the npm registry
.\build-portable.ps1
```

The command produces `dist\DeepSeek-Harness-win64-v<dsh-version>.zip` and `dist\SHA256SUMS.txt`. Every downloaded Node.js runtime is verified before it enters the package.

## FAQ

<details>
<summary><strong>Where is my data?</strong></summary>

The `dsh-home` folder beside the executable contains settings, sessions, plugins, and logs. Copy that folder to back up or migrate your data. Workspaces stay wherever you selected them.

</details>

<details>
<summary><strong>How do I uninstall it?</strong></summary>

Close the app and delete its folder. The portable build creates no installer or registry entry. To remove Electron's browser cache as well, delete `%APPDATA%\DeepSeek Harness` if it exists.

</details>

<details>
<summary><strong>Can I use the command line?</strong></summary>

Yes. Run `dsh.cmd web` for the Web UI or `dsh.cmd --profile headless "task"` for a headless task.

</details>

<details>
<summary><strong>How do updates work?</strong></summary>

The app checks this repository's published Releases at most once every 24 hours. A newer portable package opens an opt-in prompt with the current and new dsh versions. The app does not download or replace files automatically; verify the Release checksum, close the app, extract the new package, and preserve `dsh-home` and `workspace`. Set `DSH_UPDATE_CHECK=0` before launch to disable the check.

</details>

<details>
<summary><strong>Why can the first launch take longer?</strong></summary>

The first run initializes the profile and Windows antivirus software may scan the full portable package. The startup page shows five observed milestones, elapsed time, and the exact number of prepared profile components when that total is available from the package manifest. The bar advances only when work is observed as complete, so it may pause during security scanning instead of displaying a misleading time estimate. Later launches are usually faster.

</details>

## Contributing and support

Found a packaging bug or compatibility problem? [Open an issue](https://github.com/maiziman/deepseek-harness-portable/issues/new/choose) with your Windows version, package filename, reproduction steps, and sanitized logs. See [CONTRIBUTING.md](CONTRIBUTING.md) before sending a pull request and [SECURITY.md](SECURITY.md) for private vulnerability reporting.

Problems in DeepSeek Harness itself belong in the [upstream issue tracker](https://github.com/deepseek-ai/deepseek-harness/issues).

## License and attribution

The packaging tools in this repository are available under the [MIT License](LICENSE). Built ZIPs are assembled from [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (MIT, © DeepSeek AI), Node.js, Electron, and npm dependencies under their respective licenses. Exact versions are recorded in each package's `manifest.json`. The whale mark is reproduced from the upstream favicon only to identify the packaged upstream software; its inclusion does not imply DeepSeek endorsement or authorization. See [Third-party notices](THIRD_PARTY_NOTICES.md) for its source and license notice.
