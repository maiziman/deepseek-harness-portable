# Build the CedarDSH Desktop portable package for Windows x64.
#
# Produces: dist\CedarDSH-Desktop-win64-v<portable-version>.zip (+ SHA256SUMS.txt)
#
# The package layout (zip root: CedarDSH-Desktop\):
#   CedarDSH-Desktop.exe   Electron shell; double-click entry point
#   resources\app\...      shell sources (main.js)
#   runtime\               official Node.js win-x64 plus pinned pnpm for optional plugin management
#   app\node_modules\      production install of @deepseek-ai/dsh and deps
#   dsh-home\  workspace\  data dirs (DSH_HOME points here; all data stays in-package)
#   README.txt  dsh.cmd  manifest.json
#requires -Version 7.2
[CmdletBinding()]
param(
  [string]$DshVersion = '',
  [string]$PortableVersion = '',
  [string]$DshPackageDirectory = '',
  [string]$DshSourceTag = '',
  [string]$DshSourceSha = '',
  [string]$NodeVersion = 'v24.19.0',
  [string]$ElectronVersion = '44.0.0',
  [string]$ElectronMirror = 'npmmirror',
  [switch]$SkipSmoke,
  [switch]$ForceDownloadNode
)
$ErrorActionPreference = 'Stop'

$psRoot = $PSScriptRoot
$repoRoot = Split-Path $psRoot -Parent
$build = Join-Path $psRoot '.build'
$dist = Join-Path $psRoot 'dist'
$profile = Join-Path $build 'profile'
$staging = Join-Path $build 'shell-stage'
# The dependency installs run in a scratch dir OUTSIDE this repository: the
# repo root is itself a pnpm workspace (pnpm-workspace.yaml), and installing a
# package inside it with --prod trips the workspace include-deps conflict
# (ERR_PNPM_INCLUDED_DEPS_CONFLICT) against the root node_modules.
$scratch = Join-Path $env:TEMP 'dsh-portable-build'
$tools = Join-Path $scratch 'tools'
. (Join-Path $psRoot '.github\scripts\pnpm-build-policy.ps1')
. (Join-Path $psRoot '.github\scripts\pnpm-lock-policy.ps1')

# pnpm is used instead of npm for build-time installs: the dsh dependency graph
# is a few hundred packages and npm's reify planning stalls on it for minutes
# with no disk writes, while pnpm resolves and extracts it in seconds. The same
# hash-pinned pnpm payload is copied into the runtime so the official plugin
# command never falls through to Corepack or a machine-global package manager.
function Install-Pnpm([string]$Version, [string]$ExpectedSha256) {
  $target = Join-Path $build 'pnpm'
  if (Test-Path (Join-Path $target 'bin\pnpm.cjs')) { return }
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  # Cache outside .build so a failed build does not re-download the tarball.
  $cacheDir = Join-Path $psRoot '.cache'
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $tgz = Join-Path $cacheDir "pnpm-$Version.tgz"
  if (Test-Path -LiteralPath $tgz) {
    $cachedSha = (Get-FileHash -LiteralPath $tgz -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($cachedSha -cne $ExpectedSha256) {
      Remove-Item -LiteralPath $tgz -Force
      Write-Warning "removed cached pnpm $Version tarball with unexpected SHA256: $cachedSha"
    }
  }
  if (-not (Test-Path $tgz)) {
    $sources = @(
      "https://registry.npmmirror.com/pnpm/-/pnpm-$Version.tgz",
      "https://registry.npmjs.org/pnpm/-/pnpm-$Version.tgz"
    )
    $ok = $false
    foreach ($src in $sources) {
      for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        try {
          Invoke-WebRequest -Uri $src -OutFile $tgz -TimeoutSec 120
          $downloadedSha = (Get-FileHash -LiteralPath $tgz -Algorithm SHA256).Hash.ToLowerInvariant()
          if ($downloadedSha -cne $ExpectedSha256) {
            throw "SHA256 $downloadedSha does not match pinned $ExpectedSha256"
          }
          $ok = $true
        } catch {
          Write-Warning "pnpm download failed ($src, attempt $attempt): $($_.Exception.Message)"
          if (Test-Path -LiteralPath $tgz) { Remove-Item -LiteralPath $tgz -Force }
          Start-Sleep -Seconds 2
        }
      }
      if ($ok) { break }
    }
    if (-not $ok) { throw 'pnpm tarball download failed from all sources' }
  }
  $actualSha256 = (Get-FileHash -LiteralPath $tgz -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualSha256 -cne $ExpectedSha256) { throw "pnpm $Version tarball SHA256 mismatch" }
  tar -xzf $tgz -C $target --strip-components=1
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $target 'bin\pnpm.cjs'))) {
    throw 'pnpm tarball extraction failed'
  }
}

function Install-Target([string]$target, [string[]]$pkgs, [switch]$ProdOnly) {
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  # pnpm 11 build-script approvals live in pnpm-workspace.yaml. Creating one
  # here also makes this directory its own workspace root.
  $wsYaml = Join-Path $target 'pnpm-workspace.yaml'
  if (-not (Test-Path $wsYaml)) {
    if ($ProdOnly) {
      $buildPolicy = [ordered]@{
        '@deepseek-ai/dsh-subprocess-local' = $true
        '@google/genai' = $false
        'koffi' = $true
        'node-addon-require-builtin' = $false
        'node-pty' = $true
        'protobufjs' = $false
      }
    } else {
      $buildPolicy = [ordered]@{ electron = $true }
    }
    $workspaceLines = @('allowBuilds:')
    foreach ($name in $buildPolicy.Keys) {
      $quotedName = ConvertTo-Json $name -Compress
      $enabled = ([bool]$buildPolicy[$name]).ToString().ToLowerInvariant()
      $workspaceLines += "  ${quotedName}: $enabled"
    }
    $workspaceLines -join "`n" | Set-Content $wsYaml
  }
  $argsList = @('--dir', $target, 'add', '--node-linker=hoisted', '--reporter=append-only')
  if ($ProdOnly) { $argsList += '--prod' }
  $pnpmCjs = Join-Path $build 'pnpm\bin\pnpm.cjs'
  & (Join-Path $build 'runtime\node.exe') $pnpmCjs @argsList @pkgs
  if ($LASTEXITCODE -ne 0) { throw "pnpm install failed in $target (exit $LASTEXITCODE)" }
  Assert-DshPnpmBuildScriptsComplete `
    -NodePath (Join-Path $build 'runtime\node.exe') `
    -PnpmCjsPath $pnpmCjs `
    -TargetDirectory $target
}

function Install-OfficialConsumer(
  [Parameter(Mandatory)][string]$Target,
  [Parameter(Mandatory)][object]$PackageInput,
  [Parameter(Mandatory)][string]$StoreDirectory,
  [Parameter(Mandatory)][string]$CacheDirectory
) {
  $lockPath = Join-Path $Target 'pnpm-lock.yaml'
  $internalAllowlist = @($PackageInput.InternalRuntimePackages | ForEach-Object {
    [pscustomobject]@{
      Name = [string]$_.Name
      Version = [string]$_.Version
      RelativePath = [IO.Path]::GetRelativePath($Target, [string]$_.File).Replace('\', '/')
      Protocol = 'file'
    }
  })
  $lockResult = Assert-DshPnpmLockMatchesRuntimeResolutions `
    -CandidateLockPath $lockPath `
    -ExpectedConsumerLockControl $PackageInput.ConsumerLockControl `
    -ExpectedResolutions $PackageInput.ExternalRuntimeResolutions `
    -ExpectedInternalSnapshots $PackageInput.InternalRuntimeSnapshots `
    -InternalPackageAllowlist $internalAllowlist
  Write-Output "=== official runtime lock: $($lockResult.InternalCount) internal and $($lockResult.CandidateCount) external packages verified ==="

  New-Item -ItemType Directory -Force -Path $StoreDirectory, $CacheDirectory | Out-Null
  $node = Join-Path $build 'runtime\node.exe'
  $pnpmCjs = Join-Path $build 'pnpm\bin\pnpm.cjs'
  $consumerParent = [IO.Path]::GetFullPath((Split-Path $Target -Parent)).TrimEnd([char]'\', [char]'/')
  $fetchTarget = Join-Path $consumerParent '.consumer-fetch'
  if (Test-Path -LiteralPath $fetchTarget) { throw "official fetch scratch path already exists: $fetchTarget" }
  $savedCi = $env:CI
  try {
    $env:CI = 'true'
    New-Item -ItemType Directory -Path $fetchTarget | Out-Null
    foreach ($record in @($PackageInput.ConsumerFiles)) {
      Copy-Item `
        -LiteralPath (Join-Path $Target ([string]$record.relativePath)) `
        -Destination (Join-Path $fetchTarget ([string]$record.relativePath))
    }
    try {
      & $node $pnpmCjs `
        --dir $fetchTarget fetch `
        --frozen-lockfile `
        --ignore-scripts `
        --trust-lockfile `
        --registry=https://registry.npmjs.org/ `
        --store-dir $StoreDirectory `
      --cache-dir $CacheDirectory `
      --reporter=append-only
      if ($LASTEXITCODE -ne 0) { throw "official canonical-lock fetch failed (exit $LASTEXITCODE)" }
    } finally {
      $resolvedFetchTarget = [IO.Path]::GetFullPath($fetchTarget)
      if ((Split-Path $resolvedFetchTarget -Parent) -cne $consumerParent -or
        (Split-Path $resolvedFetchTarget -Leaf) -cne '.consumer-fetch') {
        throw "refusing to clean unexpected official fetch path: $resolvedFetchTarget"
      }
      if (Test-Path -LiteralPath $resolvedFetchTarget) {
        Remove-Item -LiteralPath $resolvedFetchTarget -Recurse -Force
      }
    }

    & $node $pnpmCjs `
      --dir $Target install `
      --frozen-lockfile `
      --offline `
      --prod `
      --node-linker=hoisted `
      --trust-lockfile `
      --registry=https://registry.npmjs.org/ `
      --store-dir $StoreDirectory `
      --cache-dir $CacheDirectory `
      --reporter=append-only
    if ($LASTEXITCODE -ne 0) { throw "official frozen-lock install failed (exit $LASTEXITCODE)" }
  } finally {
    $env:CI = $savedCi
  }
  Assert-DshPnpmBuildScriptsComplete `
    -NodePath $node `
    -PnpmCjsPath $pnpmCjs `
    -TargetDirectory $Target

  foreach ($record in @($PackageInput.ConsumerFiles)) {
    $relativePath = [string]$record.relativePath
    $consumerFile = Join-Path $Target $relativePath
    if (-not (Test-Path -LiteralPath $consumerFile -PathType Leaf)) {
      throw "official frozen-lock install removed consumer file: $relativePath"
    }
    $item = Get-Item -LiteralPath $consumerFile
    $sha256 = (Get-FileHash -LiteralPath $consumerFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($item.Length -ne [int64]$record.size -or $sha256 -cne [string]$record.sha256) {
      throw "official frozen-lock install changed consumer file: $relativePath"
    }
  }
}

# ── 0. resolve versions ──────────────────────────────────────────────────────
if (-not $DshVersion -and $DshPackageDirectory) {
  throw 'DshVersion is required with DshPackageDirectory'
}
if (-not $DshVersion) {
  $meta = Invoke-RestMethod -Uri 'https://registry.npmjs.org/@deepseek-ai/dsh'
  $DshVersion = [string]$meta.'dist-tags'.latest
}
$versionPattern = '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
if ($DshVersion -notmatch $versionPattern) { throw "unexpected version format: $DshVersion" }
if (-not $PortableVersion) { $PortableVersion = $DshVersion }
if ($PortableVersion -notmatch $versionPattern) { throw "unexpected portable version format: $PortableVersion" }
if ($NodeVersion -notmatch '^v?\d+\.\d+\.\d+$') { throw "unexpected Node version: $NodeVersion" }
if (-not $NodeVersion.StartsWith('v')) { $NodeVersion = 'v' + $NodeVersion }

$officialPackageInput = $null
$packageInputPath = ''
if ($DshPackageDirectory) {
  if (-not $DshSourceTag -or $DshSourceSha -cnotmatch '^[0-9a-f]{40}$') {
    throw 'DshPackageDirectory requires DshSourceTag and a lowercase 40-character DshSourceSha'
  }
  $packageInputPath = (Get-Item -LiteralPath $DshPackageDirectory -ErrorAction Stop).FullName
  $buildFull = [IO.Path]::GetFullPath($build).TrimEnd([char]'\', [char]'/')
  $scratchFull = [IO.Path]::GetFullPath($scratch).TrimEnd([char]'\', [char]'/')
  foreach ($ephemeralRoot in @($buildFull, $scratchFull)) {
    if ($packageInputPath -ceq $ephemeralRoot -or $packageInputPath.StartsWith($ephemeralRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'DshPackageDirectory must stay outside directories that the build cleans'
    }
  }
  . (Join-Path $psRoot '.github\scripts\official-dsh-package-input.ps1')
  $officialPackageInput = Get-DshOfficialPackageInput `
    -Directory $packageInputPath `
    -ExpectedVersion $DshVersion `
    -ExpectedSourceTag $DshSourceTag `
    -ExpectedSourceSha $DshSourceSha
} elseif ($DshSourceTag -or $DshSourceSha) {
  throw 'DshSourceTag and DshSourceSha are valid only with DshPackageDirectory'
}

$dshInputKind = if ($officialPackageInput) { 'official tagged source packages' } else { 'npm package' }
$pnpmVersion = if ($officialPackageInput) {
  ([string]$officialPackageInput.PackageManager).Substring('pnpm@'.Length)
} else {
  '11.7.0'
}
$trustedPnpmSha256 = @{
  '11.7.0' = 'deafa7ec98a1218b6a047289b92fbe2395c1e22d3495bb711653013218ee15ee'
}
if (-not $trustedPnpmSha256.ContainsKey($pnpmVersion)) {
  throw "no pinned SHA256 is recorded for required pnpm $pnpmVersion"
}
$pnpmSha256 = [string]$trustedPnpmSha256[$pnpmVersion]
Write-Output "=== target: portable $PortableVersion, dsh $DshVersion ($dshInputKind), node $NodeVersion, electron $ElectronVersion ==="

# Electron binary source: npmmirror (default, for CN networks), github
# (official, for CI runners), or any custom @electron/get mirror URL.
if ($ElectronMirror -eq 'npmmirror') {
  $env:ELECTRON_MIRROR = 'https://npmmirror.com/mirrors/electron/'
  $env:ELECTRON_CUSTOM_DIR = '{{ version }}'
} elseif ($ElectronMirror -eq 'github') {
  Remove-Item Env:ELECTRON_MIRROR -ErrorAction SilentlyContinue
  Remove-Item Env:ELECTRON_CUSTOM_DIR -ErrorAction SilentlyContinue
} elseif ($ElectronMirror -ne '') {
  $env:ELECTRON_MIRROR = $ElectronMirror
  $env:ELECTRON_CUSTOM_DIR = '{{ version }}'
}

# ── 1. clean and prepare ─────────────────────────────────────────────────────
# .build may also contain an independently checked-out upstream source used for
# auditing. Remove only paths owned by this script instead of treating the
# whole shared diagnostics directory as disposable.
$ownedBuildPaths = @(
  (Join-Path $build 'app'),
  (Join-Path $build 'profile'),
  (Join-Path $build 'shell-stage'),
  (Join-Path $build 'runtime'),
  (Join-Path $build 'pnpm'),
  (Join-Path $build 'smoke.png'),
  (Join-Path $build 'smoke.stderr.log'),
  (Join-Path $build 'startup-progress.png'),
  (Join-Path $build "node-$NodeVersion-win-x64.zip"),
  (Join-Path $build "node-$NodeVersion-win-x64")
)
foreach ($ownedPath in $ownedBuildPaths) {
  if (Test-Path -LiteralPath $ownedPath) { Remove-Item -LiteralPath $ownedPath -Recurse -Force }
}
if (Test-Path $scratch) { Remove-Item -Recurse -Force $scratch }
New-Item -ItemType Directory -Force -Path $build, $dist, $tools | Out-Null

Write-Output '=== desktop icon: generating Windows sizes ==='
& (Join-Path $psRoot 'shell\make-icon.ps1')

# ── 2. Node runtime ──────────────────────────────────────────────────────────
$runtimeSrc = Join-Path $repoRoot ".runtime\node-$NodeVersion-win-x64"
if ((Test-Path (Join-Path $runtimeSrc 'node.exe')) -and -not $ForceDownloadNode) {
  Write-Output "=== runtime: reusing local $runtimeSrc ==="
  Copy-Item -Recurse -Force $runtimeSrc (Join-Path $build 'runtime')
} else {
  Write-Output "=== runtime: downloading Node from nodejs.org ==="
  $zipFile = Join-Path $build "node-$NodeVersion-win-x64.zip"
  Invoke-WebRequest -Uri "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-x64.zip" -OutFile $zipFile
  $shasums = Invoke-WebRequest -Uri "https://nodejs.org/dist/$NodeVersion/SHASUMS256.txt" | Select-Object -ExpandProperty Content
  $expected = ($shasums -split "`n" | Where-Object { $_ -match "node-$NodeVersion-win-x64.zip$" } | Select-Object -First 1).Split(' ')[0]
  if (-not $expected) { throw 'could not find the expected SHA256 in SHASUMS256.txt' }
  $actual = (Get-FileHash $zipFile -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $expected.ToLower()) { throw "Node zip SHA256 mismatch: $actual != $expected" }
  tar -xf $zipFile -C $build
  if ($LASTEXITCODE -ne 0) { throw 'tar extraction of the Node zip failed' }
  Move-Item (Join-Path $build "node-$NodeVersion-win-x64") (Join-Path $build 'runtime')
}
$nodeVer = & (Join-Path $build 'runtime\node.exe') --version
if ($nodeVer.Trim() -ne $NodeVersion) { throw "bundled node reports $nodeVer, expected $NodeVersion" }

# ── 3. production install of @deepseek-ai/dsh ────────────────────────────────
# Installed into the scratch dir (outside the pnpm workspace), then copied into
# the build tree. node-linker=hoisted yields a flat npm-like node_modules, so
# the packaged tree needs no symlinks (which Windows zip extraction breaks).
Write-Output "=== installing @deepseek-ai/dsh@$DshVersion (production deps, pnpm) ==="
Install-Pnpm -Version $pnpmVersion -ExpectedSha256 $pnpmSha256
& (Join-Path $psRoot '.github\scripts\pnpm-build-policy.test.ps1') `
  -NodePath (Join-Path $build 'runtime\node.exe') `
  -PnpmCjsPath (Join-Path $build 'pnpm\bin\pnpm.cjs')
& (Join-Path $psRoot '.github\scripts\pnpm-lock-policy.test.ps1')
$scratchApp = Join-Path $scratch 'app'
if ($officialPackageInput) {
  $scratchOfficialInput = Join-Path $scratch 'official-input'
  Copy-Item -LiteralPath $packageInputPath -Destination $scratchOfficialInput -Recurse -Force
  $officialPackageInput = Get-DshOfficialPackageInput `
    -Directory $scratchOfficialInput `
    -ExpectedVersion $DshVersion `
    -ExpectedSourceTag $DshSourceTag `
    -ExpectedSourceSha $DshSourceSha
  $scratchApp = Join-Path $scratchOfficialInput 'consumer'
}
$runtimePnpm = Join-Path $build 'runtime\node_modules\pnpm'
if (Test-Path -LiteralPath $runtimePnpm) { Remove-Item -LiteralPath $runtimePnpm -Recurse -Force }
Copy-Item -LiteralPath (Join-Path $build 'pnpm') -Destination $runtimePnpm -Recurse -Force
Copy-Item -LiteralPath (Join-Path $psRoot 'shell\pnpm.cmd') -Destination (Join-Path $build 'runtime\pnpm.cmd') -Force
$runtimePnpmVersion = (& (Join-Path $build 'runtime\pnpm.cmd') --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $runtimePnpmVersion -cne $pnpmVersion) {
  throw "bundled pnpm reports '$runtimePnpmVersion', expected '$pnpmVersion'"
}
if ($officialPackageInput) {
  $runtimePackages = @($officialPackageInput.InternalRuntimePackages)
  Write-Output "=== official runtime closure: $($runtimePackages.Count) of $($officialPackageInput.Packages.Count) internal packages ==="
  Install-OfficialConsumer `
    -Target $scratchApp `
    -PackageInput $officialPackageInput `
    -StoreDirectory (Join-Path $scratch 'official-runtime-store') `
    -CacheDirectory (Join-Path $scratch 'official-runtime-cache')
} else {
  Install-Target $scratchApp -ProdOnly @("@deepseek-ai/dsh@$DshVersion")
}

# Package-manager state is not used at runtime and can retain build-machine
# file: locations when the official source tarballs were the install input.
foreach ($metadataPath in @(
  (Join-Path $scratchApp 'package.json'),
  (Join-Path $scratchApp 'pnpm-lock.yaml'),
  (Join-Path $scratchApp 'pnpm-workspace.yaml'),
  (Join-Path $scratchApp 'node_modules\.modules.yaml'),
  (Join-Path $scratchApp 'node_modules\.pnpm-workspace-state-v1.json'),
  (Join-Path $scratchApp 'node_modules\.pnpm\lock.yaml')
)) {
  if (Test-Path -LiteralPath $metadataPath -PathType Leaf) { Remove-Item -LiteralPath $metadataPath -Force }
}
$virtualStore = Join-Path $scratchApp 'node_modules\.pnpm'
if ((Test-Path -LiteralPath $virtualStore -PathType Container) -and @(Get-ChildItem -LiteralPath $virtualStore -Force).Count -eq 0) {
  Remove-Item -LiteralPath $virtualStore -Force
}
$app = Join-Path $build 'app'
if (Test-Path -LiteralPath $app) { throw 'build app staging directory was not cleaned' }
Copy-Item -Recurse -Force $scratchApp $app
if (Test-Path -LiteralPath (Join-Path $app 'app')) { throw 'build app staging unexpectedly contains a nested app copy' }
. (Join-Path $psRoot '.github\scripts\portable-build-metadata.ps1')
$metadataNormalization = Normalize-DshPortableBuildMetadata (Join-Path $app 'node_modules')
Assert-DshPortableBuildMetadataClean (Join-Path $app 'node_modules')
Write-Output "=== normalized $($metadataNormalization.SourceAnnotations) source and $($metadataNormalization.ShimAnnotations) shim annotations ==="
$desktopUpdateSource = Join-Path $psRoot 'plugin\desktop-update'
$desktopUpdateTarget = Join-Path $app 'node_modules\@cedardsh\desktop-update'
if (-not (Test-Path -LiteralPath (Join-Path $desktopUpdateSource 'lib\client.js') -PathType Leaf)) {
  throw "CedarDSH update client package is incomplete: $desktopUpdateSource"
}
New-Item -ItemType Directory -Force -Path $desktopUpdateTarget | Out-Null
Copy-Item -LiteralPath (Join-Path $desktopUpdateSource 'package.json') -Destination $desktopUpdateTarget -Force
Copy-Item -LiteralPath (Join-Path $desktopUpdateSource 'lib') -Destination $desktopUpdateTarget -Recurse -Force
$dshBin = Join-Path $app 'node_modules\@deepseek-ai\dsh\lib\bin.js'
if (-not (Test-Path $dshBin)) { throw "dsh bin missing after install: $dshBin" }
$dshPkg = Get-Content (Join-Path $app 'node_modules\@deepseek-ai\dsh\package.json') | ConvertFrom-Json
if ($dshPkg.version -cne $DshVersion) { throw "installed dsh version $($dshPkg.version) != $DshVersion" }
$installedDshVersion = (& (Join-Path $build 'runtime\node.exe') $dshBin --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $installedDshVersion -cne $DshVersion) {
  throw "installed official CLI reported '$installedDshVersion', expected '$DshVersion'"
}

# ── 4. Electron tools (build-only) ───────────────────────────────────────────
Write-Output "=== installing electron $ElectronVersion + @electron/packager (build-only, pnpm) ==="
Install-Target $tools @("electron@$ElectronVersion", '@electron/packager@20.3.0')

# Electron 44's npm package has no postinstall lifecycle; the binary lands
# through its install-electron bin (node install.js). Run it explicitly.
$electronDir = Join-Path $tools 'node_modules\electron'
if (-not (Test-Path (Join-Path $electronDir 'dist\electron.exe'))) {
  Write-Output '=== electron: downloading binary via install.js ==='
  & (Join-Path $build 'runtime\node.exe') (Join-Path $electronDir 'install.js')
  if ($LASTEXITCODE -ne 0) { throw "electron install.js failed (exit $LASTEXITCODE)" }
}
if (-not (Test-Path (Join-Path $electronDir 'dist\electron.exe'))) { throw 'electron binary missing after install.js' }
$electronZipName = "electron-v$ElectronVersion-win32-x64.zip"
$electronCacheRoot = if ($env:ELECTRON_CACHE) { $env:ELECTRON_CACHE } else { Join-Path $env:LOCALAPPDATA 'electron\Cache' }
$electronZip = Get-ChildItem $electronCacheRoot -Recurse -File -Filter $electronZipName -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $electronZip) { throw "Electron cache archive missing after install.js: $electronZipName" }

# ── 5. stage the shell app and run the packager ──────────────────────────────
$stagingShell = Join-Path $staging 'app'
New-Item -ItemType Directory -Force -Path $stagingShell | Out-Null
Copy-Item (Join-Path $psRoot 'shell\package.json') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\main.js') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\startup-progress.js') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\launch-args.js') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\process-lifecycle.js') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\diagnostics.js') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\deepseek-mark.svg') $stagingShell -ErrorAction Stop
Copy-Item (Join-Path $psRoot 'shell\update.js') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\update-install.js') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\update-helper.ps1') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\cedardsh.patch.yml') $stagingShell
$stagedIcon = Join-Path $stagingShell 'icon.ico'
Copy-Item (Join-Path $psRoot 'shell\icon.ico') $stagedIcon -ErrorAction Stop

Write-Output '=== electron-packager ==='
$productName = 'CedarDSH Desktop'
$packagerCli = @(
  (Join-Path $tools 'node_modules\@electron\packager\bin\electron-packager.mjs'),
  (Join-Path $tools 'node_modules\@electron\packager\bin\electron-packager.js'),
  (Join-Path $tools 'node_modules\@electron\packager\cli.js')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $packagerCli) { throw '@electron/packager bin not found under shell-tools' }
& (Join-Path $build 'runtime\node.exe') $packagerCli $stagingShell `
  --platform win32 --arch x64 --out $profile --overwrite --no-asar `
  --icon $stagedIcon `
  --executable-name 'CedarDSH-Desktop' `
  "--win32metadata.ProductName=$productName" `
  "--win32metadata.FileDescription=$productName" `
  '--win32metadata.OriginalFilename=CedarDSH-Desktop.exe' `
  '--win32metadata.InternalName=CedarDSH-Desktop' `
  --electron-version $ElectronVersion --electron-zip-dir $electronZip.DirectoryName `
  --app-version $PortableVersion --no-prune
if ($LASTEXITCODE -ne 0) { throw "electron-packager failed (exit $LASTEXITCODE)" }
$packed = Join-Path $profile "$productName-win32-x64"
if (-not (Test-Path $packed)) { throw "packager output missing: $packed" }
$packedExe = Join-Path $packed 'CedarDSH-Desktop.exe'
if (-not (Test-Path $packedExe -PathType Leaf)) { throw "packaged exe missing: $packedExe" }

$iconVerifier = Join-Path $psRoot '.github\scripts\verify-exe-icon.mjs'
$reseditModule = Join-Path $tools 'node_modules\resedit\dist\index.js'
if (-not (Test-Path $iconVerifier -PathType Leaf)) { throw "icon verifier missing: $iconVerifier" }
if (-not (Test-Path $reseditModule -PathType Leaf)) { throw "resedit module missing: $reseditModule" }
& (Join-Path $build 'runtime\node.exe') $iconVerifier $stagedIcon $packedExe $reseditModule
if ($LASTEXITCODE -ne 0) { throw "packaged exe icon verification failed (exit $LASTEXITCODE)" }

# ── 6. assemble the portable tree ────────────────────────────────────────────
$pkg = Join-Path $profile 'CedarDSH-Desktop'
Rename-Item $packed $pkg
$exe = Join-Path $pkg 'CedarDSH-Desktop.exe'
if (-not (Test-Path $exe)) { throw "packaged exe missing: $exe" }

Copy-Item -Recurse -Force (Join-Path $build 'runtime') (Join-Path $pkg 'runtime')
Copy-Item -Recurse -Force $app (Join-Path $pkg 'app')
New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'dsh-home'), (Join-Path $pkg 'workspace') | Out-Null
$readme = Get-Content (Join-Path $psRoot 'README.txt') -Raw
$readme = [regex]::Replace($readme, '(?m)^版本：.*$', "版本：portable $PortableVersion / dsh $DshVersion / Node $NodeVersion / Electron $ElectronVersion")
Set-Content (Join-Path $pkg 'README.txt') -Value $readme -Encoding utf8 -NoNewline
Copy-Item (Join-Path $psRoot 'THIRD_PARTY_NOTICES.md') (Join-Path $pkg 'THIRD_PARTY_NOTICES.md') -ErrorAction Stop
Copy-Item (Join-Path $psRoot 'dsh.cmd') (Join-Path $pkg 'dsh.cmd')

$ownedTopLevelEntries = @(
  @(Get-ChildItem -LiteralPath $pkg -Force | Where-Object { $_.Name -notin @('dsh-home', 'workspace') } | ForEach-Object Name)
  'manifest.json'
) | Sort-Object -Unique

$manifest = [ordered]@{
  name = 'CedarDSH Desktop'
  platform = 'win32'; arch = 'x64'
  portableVersion = $PortableVersion
  dshVersion = $DshVersion
  nodeVersion = $NodeVersion
  pnpmVersion = $pnpmVersion
  pnpmPackageSha256 = $pnpmSha256
  electronVersion = $ElectronVersion
  updateFeed = 'https://github.com/maiziman/cedardsh-desktop/releases'
  ownedTopLevelEntries = $ownedTopLevelEntries
  dshSource = if ($officialPackageInput) {
    [ordered]@{
      kind = 'official-git-tag'
      repository = 'https://github.com/deepseek-ai/deepseek-harness'
      tag = $DshSourceTag
      commit = $DshSourceSha
      packageManager = $officialPackageInput.PackageManager
      packageCount = $officialPackageInput.Packages.Count
      runtimePackageCount = $runtimePackages.Count
      internalSnapshotCount = $officialPackageInput.InternalRuntimeSnapshots.Count
      externalResolutionCount = $officialPackageInput.ExternalRuntimeResolutions.Count
      provenanceSha256 = $officialPackageInput.ProvenanceSha256
      runtimeLockSha256 = $officialPackageInput.RuntimeLockSha256
      runtimeResolutionsSha256 = $officialPackageInput.ExternalRuntimeResolutionsSha256
      internalRuntimeSnapshotsSha256 = $officialPackageInput.InternalRuntimeSnapshotsSha256
      consumerLockControlSha256 = $officialPackageInput.ConsumerLockControlSha256
      consumerLockSha256 = $officialPackageInput.ConsumerLockSha256
    }
  } else {
    [ordered]@{
      kind = 'npm'
      package = '@deepseek-ai/dsh'
      version = $DshVersion
    }
  }
  startupProfileLinkCount = $null
  builtAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  runtimeSource = if ((Test-Path (Join-Path $runtimeSrc 'node.exe')) -and -not $ForceDownloadNode) { 'local-reuse' } else { 'https://nodejs.org/dist/' }
  nodeExeSha256 = (Get-FileHash (Join-Path $pkg 'runtime\node.exe') -Algorithm SHA256).Hash.ToLower()
  shellExeSha256 = (Get-FileHash (Join-Path $pkg 'CedarDSH-Desktop.exe') -Algorithm SHA256).Hash.ToLower()
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $pkg 'manifest.json')

# ── 7. smoke test: boot the UI headless and capture a screenshot ─────────────
if (-not $SkipSmoke) {
  Write-Output '=== smoke: launching CedarDSH-Desktop.exe ==='
  $smokeOut = Join-Path $build 'smoke.png'
  $smokeError = Join-Path $build 'smoke.stderr.log'
  $startupSmokeOut = Join-Path $build 'startup-progress.png'
  $envOld = @{
    DSH_SMOKE = $env:DSH_SMOKE
    DSH_SMOKE_OUT = $env:DSH_SMOKE_OUT
    DSH_SMOKE_PROGRESS_OUT = $env:DSH_SMOKE_PROGRESS_OUT
    DSH_SMOKE_PROGRESS_STATE_OUT = $env:DSH_SMOKE_PROGRESS_STATE_OUT
  }
  try {
    $env:DSH_SMOKE = '1'
    $env:DSH_SMOKE_OUT = $smokeOut
    $env:DSH_SMOKE_PROGRESS_OUT = $startupSmokeOut
    $env:DSH_SMOKE_PROGRESS_STATE_OUT = ''
    $proc = Start-Process `
      -FilePath (Join-Path $pkg 'CedarDSH-Desktop.exe') `
      -WorkingDirectory $pkg `
      -RedirectStandardError $smokeError `
      -PassThru
    $smokeTimeoutMs = 270000
    if (-not $proc.WaitForExit($smokeTimeoutMs)) {
      $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
      $killer = Start-Process -FilePath $taskkill -ArgumentList @('/PID', [string]$proc.Id, '/T', '/F') -WindowStyle Hidden -PassThru
      $killerTimedOut = -not $killer.WaitForExit(15000)
      if ($killerTimedOut) {
        Stop-Process -Id $killer.Id -Force -ErrorAction SilentlyContinue
        [void]$killer.WaitForExit(5000)
      }
      $killerExitCode = if ($killerTimedOut) { -1 } else { $killer.ExitCode }
      if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
      if (-not $proc.WaitForExit(10000)) { throw 'smoke cleanup could not terminate the desktop process within 10s' }
      if ($killerExitCode -ne 0) { throw "smoke cleanup could not terminate the complete process tree (taskkill exit $killerExitCode)" }
      throw 'smoke test timed out after 270s'
    }
    if ($proc.ExitCode -ne 0) {
      throw "smoke test failed (exit $($proc.ExitCode)); see $pkg\dsh-home\logs\server.log"
    }
    if (-not (Test-Path $smokeOut)) { throw 'smoke test passed but no screenshot was written' }
    if (-not (Test-Path $startupSmokeOut)) { throw 'smoke test passed but no startup progress screenshot was written' }
    Write-Output "smoke OK: UI $((Get-Item $smokeOut).Length) bytes; startup $((Get-Item $startupSmokeOut).Length) bytes"
  } finally {
    $env:DSH_SMOKE = $envOld.DSH_SMOKE
    $env:DSH_SMOKE_OUT = $envOld.DSH_SMOKE_OUT
    $env:DSH_SMOKE_PROGRESS_OUT = $envOld.DSH_SMOKE_PROGRESS_OUT
    $env:DSH_SMOKE_PROGRESS_STATE_OUT = $envOld.DSH_SMOKE_PROGRESS_STATE_OUT
  }

  $profileModules = Join-Path $pkg 'dsh-home\profiles\node_modules'
  $packagedModulesRoot = [IO.Path]::GetFullPath((Join-Path $pkg 'app\node_modules')).TrimEnd([char]'\', [char]'/')
  $profileLinkCount = 0
  foreach ($entry in @(Get-ChildItem $profileModules -Force)) {
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      $target = [IO.Path]::GetFullPath([string]$entry.Target)
      if ($target -ceq $packagedModulesRoot -or $target.StartsWith($packagedModulesRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $profileLinkCount++ }
    } elseif ($entry.PSIsContainer -and $entry.Name.StartsWith('@')) {
      foreach ($child in @(Get-ChildItem $entry.FullName -Force)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          $target = [IO.Path]::GetFullPath([string]$child.Target)
          if ($target -ceq $packagedModulesRoot -or $target.StartsWith($packagedModulesRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $profileLinkCount++ }
        }
      }
    }
  }
  if ($profileLinkCount -le 0) { throw 'smoke test initialized no profile component links' }
  $manifest['startupProfileLinkCount'] = $profileLinkCount
  $manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $pkg 'manifest.json')
  Write-Output "startup progress metadata: $profileLinkCount profile component links"
} else {
  Write-Output '=== smoke skipped ==='
}

# The smoke test auto-initialized dsh-home (profiles/node_modules junctions
# plus logs). Ship a pristine home: junctions do not survive zip extraction
# as links, and dsh refuses a non-symlink fallback entry. The target machine
# re-initializes the home on first run.
Remove-Item -Recurse -Force (Join-Path $pkg 'dsh-home') -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'dsh-home') | Out-Null
$sensitiveBuildPaths = @(
  $repoRoot,
  $psRoot,
  $build,
  $profile,
  $scratch,
  $env:RUNNER_WORKSPACE,
  $env:GITHUB_WORKSPACE
)
# Scan build-owned locations, not machine-wide home or temporary-directory
# prefixes. Third-party native binaries can legitimately retain those generic
# prefixes from their own upstream CI build.
if ($packageInputPath) { $sensitiveBuildPaths += $packageInputPath }
$pathScan = Assert-DshPortableTreeHasNoSensitivePaths `
  -Root $pkg `
  -SensitivePaths @($sensitiveBuildPaths | Where-Object { $_ } | Sort-Object -Unique)
Write-Output "=== build path scan: $($pathScan.Files) files against $($pathScan.Patterns) sensitive forms ==="

# ── 8. zip + checksums ───────────────────────────────────────────────────────
$zipName = "CedarDSH-Desktop-win64-v$PortableVersion.zip"
$zipPath = Join-Path $dist $zipName
Write-Output "=== zipping $zipName ==="
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
if (Get-Command tar -ErrorAction SilentlyContinue) {
  tar -a -c -f $zipPath -C $profile 'CedarDSH-Desktop'
  if ($LASTEXITCODE -ne 0) { throw "zip creation via tar failed (exit $LASTEXITCODE)" }
} else {
  Compress-Archive -Path (Join-Path $profile 'CedarDSH-Desktop') -DestinationPath $zipPath -CompressionLevel Optimal
}
$sha = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
"$sha  $zipName" | Set-Content (Join-Path $dist 'SHA256SUMS.txt')

$sizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Output "=== DONE: $zipPath ($sizeMb MB) ==="
Write-Output "SHA256: $sha"
