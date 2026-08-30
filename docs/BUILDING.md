# Building DeepSeek Harness Pure Portable

This reference describes how the portable ZIP is assembled, verified, and published. For installation and product use, start with the [project README](../README.md).

## Requirements

- Windows 10 or newer, x64
- PowerShell 7.2 or newer (`build-portable.ps1` and `verify-package.ps1` enforce this requirement)
- Access to the npm registry and the selected Electron binary mirror; an official source-package build also needs GitHub access
- Enough free space for the Node.js runtime, production dependencies, Electron, and the final ZIP

## Build

```powershell
.\build-portable.ps1
```

| Parameter | Meaning |
|---|---|
| `-DshVersion 0.1.1-rc.2` | Published `@deepseek-ai/dsh` version; defaults to npm latest. |
| `-DshPackageDirectory C:\Build\dsh-packages` | Optional complete package set staged from an exact official `dsh-v*` tag; without it, the build installs `@deepseek-ai/dsh` from npm. |
| `-DshSourceTag dsh-v0.1.2-alpha.1` | Exact official source tag recorded in and checked against the staged package provenance; required with `-DshPackageDirectory`. |
| `-DshSourceSha cd5ef814...` | Full 40-character commit for the official source tag; required with `-DshPackageDirectory`. |
| `-PortableVersion 1.2.1` | Project release version used by the tag, ZIP, Electron metadata, manifest, and update comparison; defaults to the dsh version for untagged local builds. |
| `-NodeVersion v24.19.0` | Official Node.js version satisfying the dsh engine requirement. |
| `-ElectronVersion 44.0.0` | Electron runtime version. |
| `-ElectronMirror npmmirror` | Electron source: `npmmirror`, `github`, or a custom mirror URL. |
| `-SkipSmoke` | Skip the in-package boot probe. |
| `-ForceDownloadNode` | Download Node.js again and repeat the official checksum verification. |

The build writes `dist\DeepSeek-Harness-win64-v<portable-version>.zip` and `dist\SHA256SUMS.txt`. The ZIP's `manifest.json` records `portableVersion` separately from the official `dshVersion`, plus the Node.js, pnpm, and Electron versions, the pnpm package hash, upstream source tag and commit when supplied, and SHA256 values for key inputs and binaries. A tagged Release, its ZIP, and `portableVersion` must use the same Semantic Version.

The source-package form keeps the selected official checkout unchanged. Upstream's own `release:verify`, `build:official`, and `release:pack` commands produce the `dsh`, `vendor`, and `landlock` tarball families. `.github/scripts/stage-official-dsh-packages.ps1` writes a closed package directory containing those tarballs, `provenance.json`, and `SHA256SUMS.txt`; the portable build rejects a missing archive, duplicate package identity, unexpected family, version mismatch, source mismatch, size mismatch, or checksum mismatch.

The read-only source job then maps every packed runtime package back to its verified official lockfile importer, derives the production, optional, and required-peer graph, and removes only source-workspace optional packages whose declared platform rules exclude Windows x64. It creates one canonical consumer manifest, workspace policy, and lockfile, then records the exact internal package set, every external registry resolution, package metadata, snapshot dependency edge, both runtime-model SHA256 values, and all three consumer-file SHA256 values in schema-4 provenance. A separate consumer-control model records the lockfile version, root importer specifiers and resolved versions, root settings, every override, and every patched-dependency content hash; its canonical SHA256 binds the complete model. Package metadata includes platform and libc rules, engines, binary-entry presence, bundled dependencies, deprecation, identity, peer declarations, and peer metadata; unsupported package, snapshot, importer, setting, override, patch, or root-lock fields fail closed. Both Windows builds copy and revalidate that complete directory, compare the canonical lock against the recorded internal, external, and consumer-control models, fetch its content from the official npm registry, and perform a frozen offline hoisted install. The install uses pnpm's trusted-lock mode only after the full lockfile hash and semantic models have passed those checks, so pnpm does not perform a second metadata lookup against a machine-level registry. After installation, packaging changes no executable runtime text or runtime configuration. It only rewrites generated CSS source-region comments to repository-relative paths and removes pnpm shim target comments; tests prove both privacy transformations preserve executable text. A final binary-safe scan rejects the actual repository, scratch, package-input, runner, or temporary path in any packaged file, including slash-normalized, escaped, URI, and UTF-16 forms.

```powershell
.\build-portable.ps1 `
  -DshVersion 0.1.2-alpha.1 `
  -PortableVersion 1.2.1 `
  -DshPackageDirectory C:\Build\dsh-packages `
  -DshSourceTag dsh-v0.1.2-alpha.1 `
  -DshSourceSha cd5ef8148158c3a752a658978873241fdf8e2bbc
```

## Assembly pipeline

```text
build-portable.ps1
 ├─ resolve and validate component versions
 ├─ verify an official tagged package set and its canonical Windows lock, or resolve the selected published npm package
 ├─ validate the transparent icon master and generate nine Windows icon sizes
 ├─ download the official Windows x64 Node.js runtime and verify SHA256
 ├─ fetch the verified lock, install it frozen and offline into a ZIP-safe hoisted tree, and add hash-pinned pnpm for explicit plugin commands
 ├─ remove build-machine paths from non-executable generated annotations
 ├─ package the Electron desktop shell and verify its PE icon frames, name, filename, and version metadata
 ├─ assemble runtime/, app/, dsh-home/, workspace/, notices, README.txt, and dsh.cmd
 ├─ boot the packaged app, wait for the local server, and capture the rendered UI
 └─ create the ZIP and SHA256SUMS.txt
```

The default ZIP contains no capability plugin and does not install one at startup. Its hash-pinned pnpm payload exists only so an explicit official `dsh plugin` command does not fall through to Corepack or a machine-global package manager. The desktop shell renders its startup page before spawning the bundled Node.js executable with `dsh web --no-open --port 0`. The page reports observed directory, runtime, profile-component, profile, server, and interface milestones plus elapsed time; during first-run fallback creation, it counts completed package-owned component links against the total recorded by the build smoke test in `manifest.json`. The shell reads the announced loopback URL, loads it in the desktop window, focuses the existing window on a second launch, and stops the server process tree when the window closes.

## Automatic upstream tracking

The `dsh-upstream-watch` workflow runs every six hours and can also be started manually. It selects the highest Semantic Version from the official `deepseek-ai/deepseek-harness` `dsh-v*` Git tags and records that tag's commit. The workflow checks out that exact commit, verifies that the tag, root version, CLI version, and declared pnpm version agree, and runs the upstream `release:verify`, `build:official`, and `release:pack` process. It does not wait for the same version to appear on npm and does not use npm `latest` or `next` to identify an upstream release.

An official tag without a complete public portable package enters the Windows Server 2022 and 2025 build-and-verify matrix after its upstream package set passes the source and provenance checks. Both environments build independently; a second two-runner check then downloads the exact Windows 2025 artifact selected for publication and verifies that same ZIP on both Windows versions. The watcher allocates the next patch after the highest complete public strict `v<SemVer>` portable Release; the historical `v1.0.0` through `v1.2.0` naming mismatch is accepted only for their published `v0.1.1-rc.2` ZIPs, so the first new-format automatic package is `v1.2.1`. The Release tag, ZIP, body marker, Electron version, manifest portable version, and GitHub prerelease state follow the portable version. The body and manifest separately record the official dsh version, source tag, exact source commit, and any upstream preview label.

After both runners pass, the workflow enters the same publication lock used by manual portable tags, rescans public Releases, and confirms that its dsh mapping and next-patch allocation are still current. It resolves the previous portable tag to one exact commit before generating notes, then creates a private Draft Release with an isolated temporary tag and retains its exact Release ID. The final step requires exactly one matching ZIP and `SHA256SUMS.txt` whose uploaded states, sizes, and remote SHA256 digests match the verified local files. Immediately before publication, both automatic and manual paths rescan public Releases, require the same version allocation again, and confirm the previous tag still resolves to its recorded commit. The staging step records SHA256 values for the Draft body and name; the finalizer rechecks both and writes those verified values in the same API mutation that assigns the public `v<portable-version>` tag and publishes the Release. Tag-triggered portable and plugin runs require the triggering tag to remain at its original commit, while the automatic watcher alone may create a missing public tag. The workflow never deletes or replaces a Release asset; a complete public Release makes the rerun read-only, and an interrupted private Draft does not block a later run. Build jobs have read-only repository access and do not retain Git credentials.

The packaged desktop app reads only complete published Releases whose strict `v<SemVer>` tag, ZIP version, and uploaded asset records agree. At most once every 24 hours it compares the highest valid portable version with `manifest.json`; packages created before `portableVersion` use their legacy `dshVersion` value. A newer version produces an opt-in download prompt, including desktop-shell fixes that keep the same dsh dependency. The app does not download or replace files. Set `DSH_UPDATE_CHECK=0` before launch to disable the network check.

## Independent optional plugin release

`DSH Custom API Capabilities` is an independent, opt-in Bundle with its own `plugin-model-capabilities-v<version>` tag and GitHub Release. The portable ZIP neither contains nor installs it. The `plugin-release` workflow requires the tag version to equal `plugins/dsh-model-capabilities/package.json`, runs the plugin tests, confirms the npm tarball contains exactly the seven published files, and generates a one-line `SHA256SUMS.txt`. It installs that tarball through the official CLI in a clean checkout of the exact upstream tag and commit recorded in `.github/plugin-compatibility.json`, expands the Web profile, and boots its command surface. A separate Windows gate builds and verifies a pure portable ZIP, extracts it into an empty directory with no global pnpm or Corepack cache, installs the exact plugin candidate from an empty pnpm store in offline mode, and confirms the expanded Web configuration. Only then does publication stage the `.tgz` and checksum under an isolated private Draft tag, verify the exact remote sizes and SHA256 digests, and assign the public plugin tag with GitHub's Latest flag disabled. Semantic Version prerelease labels are also projected to GitHub's prerelease state. Portable Releases retain their separate ZIP-and-checksum asset rule and version lifecycle.

## Verification

```powershell
.\verify-package.ps1
.\verify-package.ps1 -ZipPath .\dist\DeepSeek-Harness-win64-v1.2.1.zip -ExpectedPortableVersion 1.2.1 -ExpectedDshVersion 0.1.2-alpha.1
```

The build rejects an icon master without transparent and opaque pixels, an ICO without exactly 16, 20, 24, 32, 40, 48, 64, 128, and 256 px RGBA PNG frames, or a packaged EXE whose PE icon group differs from any source frame. Before compression, the build performs the full binary-sensitive scan for the actual repository, build-owned scratch, runner workspace, and package-input paths. It intentionally does not reject a machine-wide user-home or temporary-directory prefix because a third-party native binary can legitimately retain that generic prefix from its own upstream build. The verification probe checks a single top-level directory, absence of pre-launch reparse points, an empty `dsh-home`, extraction completeness, third-party notices, manifest and Node.js/pnpm runtime versions, the canonical-lock and runtime-map hashes, PE product and filename metadata, absence of generated absolute-path annotations, package-manager state, and default plugins, a real server boot, URL discovery, clean shutdown, and first-run profile initialization. It captures both UI images and machine-readable startup evidence proving that the rendered component numerator and denominator came from package-owned links and match the manifest total.

GitHub Actions repeats the build and probe on fresh Windows Server 2022 and 2025 runners. Branch pushes select the highest official `dsh-v*` tag once and upload short-lived workflow artifacts. The upstream watcher's optional manual version is only an assertion of that unique highest official tag; it cannot publish a historical dsh version into the forward update stream. A `v*` tag uses its own version as `portableVersion` and reads the exact dsh version committed in `.github/portable-dsh-version.txt`, then resolves that version to its official source tag and commit; update the file before creating a manual portable tag. Generated notes compare only with the preceding complete public portable Release whose tag is strict `v<SemVer>`, excluding failed tags plus legacy upstream and plugin tag families. Upstream tracking follows the same monotonic `v*` stream and publishes a verified next patch after an official tagged source passes the upstream build, package, and portable verification steps. A `plugin-model-capabilities-v*` tag runs only the independent plugin publication workflow.

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
