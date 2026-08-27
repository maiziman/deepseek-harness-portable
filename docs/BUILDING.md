# Building and verification

This reference describes how the portable ZIP is assembled, verified, and published. For installation and product use, start with the [project README](../README.md).

## Requirements

- Windows 10 or newer, x64
- PowerShell 7 or Windows PowerShell 5.1
- Access to the npm registry and the selected Electron binary mirror
- Enough free space for the Node.js runtime, production dependencies, Electron, and the final ZIP

## Build

```powershell
.\build-portable.ps1
```

| Parameter | Meaning |
|---|---|
| `-DshVersion 0.1.1-rc.2` | Published `@deepseek-ai/dsh` version; defaults to npm latest. |
| `-NodeVersion v24.19.0` | Official Node.js version satisfying the dsh engine requirement. |
| `-ElectronVersion 44.0.0` | Electron runtime version. |
| `-ElectronMirror npmmirror` | Electron source: `npmmirror`, `github`, or a custom mirror URL. |
| `-SkipSmoke` | Skip the in-package boot probe. |
| `-ForceDownloadNode` | Download Node.js again and repeat the official checksum verification. |

The build writes `dist\DeepSeek-Harness-win64-v<dsh-version>.zip` and `dist\SHA256SUMS.txt`. The ZIP's `manifest.json` records the dsh, Node.js, and Electron versions plus SHA256 values for key binaries.

## Assembly pipeline

```text
build-portable.ps1
 ├─ resolve and validate component versions
 ├─ download the official Windows x64 Node.js runtime and verify SHA256
 ├─ install production dependencies into a ZIP-safe, hoisted tree
 ├─ package the Electron desktop shell
 ├─ assemble runtime/, app/, dsh-home/, workspace/, README.txt, and dsh.cmd
 ├─ boot the packaged app, wait for the local server, and capture the rendered UI
 └─ create the ZIP and SHA256SUMS.txt
```

The desktop shell starts the bundled Node.js executable with `dsh web --no-open --port 0`. It reads the announced loopback URL, loads it in the desktop window, focuses the existing window on a second launch, and stops the server process tree when the window closes.

## Automatic upstream tracking

The `dsh-upstream-watch` workflow runs every six hours and can also be started manually. It reads the official npm `latest` tag, then checks public and Draft Releases for a matching portable ZIP. A version without a package enters the Windows Server 2022 and 2025 build-and-verify matrix.

After both runners pass, the workflow creates a Draft Release tagged `dsh-v<version>`. The draft includes the Windows 2025 ZIP, `SHA256SUMS.txt`, a machine-readable dsh version marker, and a publication checklist. A maintainer must review and publish the draft; the workflow never exposes a new upstream version directly to users.

The packaged desktop app reads only published Releases. At most once every 24 hours it compares the highest valid portable asset version with `manifest.json`. A newer version produces an opt-in download prompt; the app does not download or replace files. Set `DSH_UPDATE_CHECK=0` before launch to disable the network check.

## Verification

```powershell
.\verify-package.ps1
.\verify-package.ps1 -ZipPath .\dist\DeepSeek-Harness-win64-v0.1.1-rc.2.zip
```

The verification probe checks extraction completeness, manifest and runtime versions, a real server boot, URL discovery, UI rendering, clean shutdown, and first-run profile initialization.

GitHub Actions repeats the build and probe on fresh Windows Server 2022 and 2025 runners. Pushes upload short-lived workflow artifacts; a `v*` tag publishes the ZIP and checksum to a GitHub Release, while upstream tracking prepares a Draft Release for maintainer approval.

GitHub runners use Windows Server. Before publishing a user-facing release, spot-check the same ZIP on Windows 10 or 11, including SmartScreen behavior and common antivirus software.

## Repository layout

```text
.
├─ build-portable.ps1       build, assemble, smoke-test, and archive
├─ verify-package.ps1       deterministic compatibility probe
├─ watch-progress.ps1       concise progress output for long local builds
├─ shell/                   Electron shell and application icon
├─ .github/workflows/       clean-machine matrix and tagged releases
├─ docs/                    README and social-preview assets
└─ dist/ .build/ .cache/    ignored generated files
```
