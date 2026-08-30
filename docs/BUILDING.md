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
| `-PortableVersion 1.2.1` | Project release version used by the tag, ZIP, Electron metadata, manifest, and update comparison; defaults to the dsh version for untagged local builds. |
| `-NodeVersion v24.19.0` | Official Node.js version satisfying the dsh engine requirement. |
| `-ElectronVersion 44.0.0` | Electron runtime version. |
| `-ElectronMirror npmmirror` | Electron source: `npmmirror`, `github`, or a custom mirror URL. |
| `-SkipSmoke` | Skip the in-package boot probe. |
| `-ForceDownloadNode` | Download Node.js again and repeat the official checksum verification. |

The build writes `dist\DeepSeek-Harness-win64-v<portable-version>.zip` and `dist\SHA256SUMS.txt`. The ZIP's `manifest.json` records `portableVersion` separately from the official `dshVersion`, plus the Node.js and Electron versions and SHA256 values for key binaries. A tagged Release, its ZIP, and `portableVersion` must use the same Semantic Version.

## Assembly pipeline

```text
build-portable.ps1
 ├─ resolve and validate component versions
 ├─ validate the transparent icon master and generate nine Windows icon sizes
 ├─ download the official Windows x64 Node.js runtime and verify SHA256
 ├─ install production dependencies into a ZIP-safe, hoisted tree
 ├─ package the Electron desktop shell and compare all embedded PE icon frames with the source ICO
 ├─ assemble runtime/, app/, dsh-home/, workspace/, notices, README.txt, and dsh.cmd
 ├─ boot the packaged app, wait for the local server, and capture the rendered UI
 └─ create the ZIP and SHA256SUMS.txt
```

The desktop shell renders its startup page before spawning the bundled Node.js executable with `dsh web --no-open --port 0`. The page reports observed directory, runtime, profile-component, profile, server, and interface milestones plus elapsed time; during first-run fallback creation, it counts completed component links against the total recorded by the build smoke test in `manifest.json`. The shell reads the announced loopback URL, loads it in the desktop window, focuses the existing window on a second launch, and stops the server process tree when the window closes.

## Automatic upstream tracking

The `dsh-upstream-watch` workflow runs every six hours and can also be started manually. It selects the highest Semantic Version from the official `deepseek-ai/deepseek-harness` `dsh-v*` Git tags and records that tag's commit. If the exact `@deepseek-ai/dsh` version is not yet present in the npm registry, the run reports the pending tag and exits successfully; a later scheduled run retries. This keeps source-release discovery independent from npm `latest` and `next` dist-tags without attempting to install a package that does not exist.

Once the exact npm package exists, a version without a complete public package enters the Windows Server 2022 and 2025 build-and-verify matrix. The watcher allocates the next patch after the highest complete public strict `v<SemVer>` portable Release; the historical `v1.0.0` through `v1.2.0` naming mismatch is accepted only as a migration floor, so the first new-format automatic package is `v1.2.1`. The Release tag, ZIP, body marker, Electron version, and manifest portable version must agree. The body separately records the official dsh version, source tag, and exact source commit. A preview upstream dsh package marks the GitHub Release as a prerelease even when the allocated portable tag has no prerelease suffix.

After both runners pass, the workflow enters the same publication lock used by manual portable tags, rescans public Releases, and confirms that its dsh mapping and next-patch allocation are still current. It then creates a private Draft Release with an isolated temporary tag and retains its exact Release ID. The final step requires exactly one matching ZIP and `SHA256SUMS.txt` whose uploaded states, sizes, and remote SHA256 digests match the verified local files. It also binds the Draft body and target commit by SHA256 before assigning the public `v<portable-version>` tag and publishing in one API update. It never deletes or replaces a Release asset; a complete public Release makes the rerun read-only, and an interrupted private Draft does not block a later run. Build jobs have read-only repository access and do not retain Git credentials.

The packaged desktop app reads only complete published Releases whose strict `v<SemVer>` tag, ZIP version, and uploaded asset records agree. At most once every 24 hours it compares the highest valid portable version with `manifest.json`; packages created before `portableVersion` use their legacy `dshVersion` value. A newer version produces an opt-in download prompt, including shell or plugin fixes that keep the same dsh dependency. The app does not download or replace files. Set `DSH_UPDATE_CHECK=0` before launch to disable the network check.

## Independent plugin release

The model-capabilities Bundle has its own `plugin-model-capabilities-v<version>` tag and GitHub Release. The `plugin-release` workflow requires the tag version to equal `plugins/dsh-model-capabilities/package.json`, runs the plugin tests, confirms the npm tarball contains exactly the seven published files, and generates a one-line `SHA256SUMS.txt`. It then installs that tarball through the official CLI in a clean checkout of the exact upstream tag and commit recorded in `.github/plugin-compatibility.json`, expands the Web profile, and boots its command surface. It stages the `.tgz` and checksum under an isolated private Draft tag only after those checks pass, verifies the exact remote sizes and SHA256 digests, then assigns the public plugin tag with GitHub's Latest flag disabled. Semantic Version prerelease labels are also projected to GitHub's prerelease state. Portable Releases retain their separate ZIP-and-checksum asset rule and version lifecycle.

## Verification

```powershell
.\verify-package.ps1
.\verify-package.ps1 -ZipPath .\dist\DeepSeek-Harness-win64-v1.2.1.zip -ExpectedPortableVersion 1.2.1 -ExpectedDshVersion 0.1.2-alpha.1
```

The build rejects an icon master without transparent and opaque pixels, an ICO without exactly 16, 20, 24, 32, 40, 48, 64, 128, and 256 px RGBA PNG frames, or a packaged EXE whose PE icon group differs from any source frame. The verification probe then checks extraction completeness, the bundled third-party notice, manifest and runtime versions, rendered startup-progress and final-UI screenshots, a real server boot, URL discovery, clean shutdown, and first-run profile initialization. It also requires the initialized component-link count to match the package manifest.

GitHub Actions repeats the build and probe on fresh Windows Server 2022 and 2025 runners. Branch pushes resolve npm `latest` once and upload short-lived workflow artifacts. A `v*` tag uses its own version as `portableVersion` and reads the exact package version committed in `.github/portable-dsh-version.txt`, so rerunning the tag cannot silently change either identity; update that file before creating a manual portable tag. Its generated notes compare only with the preceding complete public portable Release whose tag is strict `v<SemVer>`, excluding failed tags plus legacy upstream and plugin tag families. Upstream tracking follows the same monotonic `v*` stream and publishes a verified next patch when a new official dsh package becomes installable. A `plugin-model-capabilities-v*` tag runs only the independent plugin publication workflow.

GitHub runners use Windows Server. Periodically spot-check a published ZIP on Windows 10 or 11, including SmartScreen behavior and common antivirus software.

## Repository layout

```text
.
├─ build-portable.ps1       build, assemble, smoke-test, and archive
├─ verify-package.ps1       deterministic compatibility probe
├─ watch-progress.ps1       concise progress output for long local builds
├─ plugins/                 independently installable Bundles
├─ shell/                   Electron shell and application icon
├─ .github/workflows/       clean-machine matrix and tagged releases
├─ docs/                    README and social-preview assets
└─ dist/ .build/ .cache/    ignored generated files
```
