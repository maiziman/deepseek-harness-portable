<h1 align="center">CedarDSH Desktop</h1>

<p align="center"><strong>DeepSeek Harness for Windows. Download one ZIP, extract it, and run.</strong></p>

<p align="center">
  <a href="https://github.com/maiziman/cedardsh-desktop/releases/latest"><strong>Download for Windows</strong></a>
  · <a href="README.zh.md">中文说明</a>
</p>

<p align="center">
  <a href="https://github.com/maiziman/cedardsh-desktop/actions"><img alt="Windows verification" src="https://img.shields.io/github/actions/workflow/status/maiziman/cedardsh-desktop/portable-verify.yml?branch=main&amp;label=Windows%20verified"></a>
  <a href="https://github.com/maiziman/cedardsh-desktop/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/maiziman/cedardsh-desktop?include_prereleases"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/maiziman/cedardsh-desktop"></a>
  <img alt="Windows x64" src="https://img.shields.io/badge/Windows-10%2F11%20x64-0078d4?logo=windows11">
</p>

<p align="center">
  <img src="docs/social-preview.png" alt="CedarDSH Desktop — portable DeepSeek Harness for Windows" width="100%">
</p>

## Start in three steps

1. Download `DeepSeek-Harness-win64-v<version>.zip` from [Releases](https://github.com/maiziman/cedardsh-desktop/releases/latest).
2. Extract the whole ZIP to a short path such as `C:\Tools\CedarDSH`.
3. Double-click `DeepSeek-Harness.exe`, add your model provider, choose a workspace, and start a session.

No Node.js, installer, or administrator access is required. Windows SmartScreen may warn about an unrecognized app because the community build is not code-signed; compare the ZIP with `SHA256SUMS.txt` before choosing **More info → Run anyway**.

<p align="center">
  <img src="docs/product-overview.png" alt="CedarDSH Desktop interface" width="100%">
</p>

## What you get

- **One portable folder:** the app, runtime, settings, sessions, plugins, and logs stay together.
- **A normal desktop window:** closing the window also stops the local DeepSeek Harness server.
- **Official tagged source:** the selected upstream tag is built with DeepSeek Harness's own release process and without source patches.
- **Update prompts:** the app checks published CedarDSH Desktop releases once a day and asks before opening the download page.
- **Clean Windows checks:** every release is built and started on fresh Windows Server 2022 and 2025 runners before publication.

Your data is in `dsh-home` beside the EXE. When updating, close the app, extract the new ZIP, and keep your existing `dsh-home` and `workspace` folders.

> [!IMPORTANT]
> CedarDSH Desktop is an independent community package, not a DeepSeek product or official release channel. “DeepSeek Harness” and its whale mark identify the packaged upstream software.

## Optional model capability detection

Need a custom OpenAI-compatible model to report whether it supports reasoning or images? Install the separate [CedarDSH Model Probe](https://github.com/maiziman/cedardsh-model-probe). It is not included in the desktop ZIP.

## Useful answers

- **Uninstall:** close the app and delete its folder. No installer or registry entry is created.
- **Back up:** copy `dsh-home`; your selected workspaces remain in their original locations.
- **First launch is slow:** the startup page shows real completed stages while Windows security software scans the package. Later launches are usually faster.
- **Updates are not silent:** the app only shows a prompt. You choose when to download and replace the program files.
- **Command line:** run `dsh.cmd web` for the Web UI or `dsh.cmd --profile headless "task"` for one headless task.

## Build and verification

Run `./build-portable.ps1` on Windows 10 or later with PowerShell 7.2 or later. The build produces the ZIP and `SHA256SUMS.txt`; `manifest.json` records the CedarDSH Desktop version, packaged DSH version, upstream source tag and commit, and runtime hashes.

See [Building and verification](docs/BUILDING.md) for provenance and release details. Packaging issues belong in this repository's [issue tracker](https://github.com/maiziman/cedardsh-desktop/issues); DeepSeek Harness issues belong in the [upstream tracker](https://github.com/deepseek-ai/deepseek-harness/issues).

## License

The CedarDSH Desktop packaging tools use the [MIT License](LICENSE). Built ZIPs contain DeepSeek Harness, Node.js, Electron, and npm dependencies under their own licenses. See [Third-party notices](THIRD_PARTY_NOTICES.md).
