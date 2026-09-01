# Compatibility probe for the portable package: deterministic pass/fail with
# one command, runnable on any Windows machine, in Windows Sandbox, and on
# GitHub Actions windows runners.
#
# What it verifies (the same checks a real user's first run performs):
#   1. the ZIP extracts to a complete tree (exe, manifest, runtime, app, notices)
#   2. the bundled node.exe is the manifest version
#   3. the packaged app boots: startup progress and final UI render,
#      the server announces its URL, and the process exits 0
#   4. first-run profile auto-initialization happens
#
# Usage:
#   .\verify-package.ps1                       # newest zip in dist\
#   .\verify-package.ps1 -ZipPath X.zip        # specific package
#   .\verify-package.ps1 -ZipPath X.zip -ExpectedPortableVersion 1.2.1 -ExpectedDshVersion 0.1.2-alpha.2
#   .\verify-package.ps1 -Keep                 # keep the extracted tree
#requires -Version 7.2
[CmdletBinding()]
param(
  [string]$ZipPath = '',
  [string]$WorkDir = '',
  [string]$ExpectedPortableVersion = '',
  [string]$ExpectedDshVersion = '',
  [string]$ExpectedDshSourceTag = '',
  [string]$ExpectedDshSourceSha = '',
  [switch]$Keep
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root '.github\scripts\portable-build-metadata.ps1')

function Get-ProfileLinkCount([string]$ModulesDir, [string]$PackagedModulesDir) {
  $packagedRoot = [IO.Path]::GetFullPath($PackagedModulesDir).TrimEnd([char]'\', [char]'/')
  $count = 0
  foreach ($entry in @(Get-ChildItem $ModulesDir -Force)) {
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      $target = [IO.Path]::GetFullPath([string]$entry.Target)
      if ($target -ceq $packagedRoot -or $target.StartsWith($packagedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $count++ }
    } elseif ($entry.PSIsContainer -and $entry.Name.StartsWith('@')) {
      foreach ($child in @(Get-ChildItem $entry.FullName -Force)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          $target = [IO.Path]::GetFullPath([string]$child.Target)
          if ($target -ceq $packagedRoot -or $target.StartsWith($packagedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $count++ }
        }
      }
    }
  }
  return $count
}

if (-not $ZipPath) {
  $candidates = Get-ChildItem (Join-Path $root 'dist\*.zip') -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
  if ($candidates) { $ZipPath = $candidates[0].FullName }
}
if (-not $ZipPath -or -not (Test-Path $ZipPath)) { throw 'no ZIP found (pass -ZipPath or build first)' }
if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ('dsh-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
Write-Output "=== verify: $ZipPath"

# ── 1. extract ───────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
if (Get-Command tar -ErrorAction SilentlyContinue) { tar -xf $ZipPath -C $WorkDir }
else { Expand-Archive -Path $ZipPath -DestinationPath $WorkDir -Force }
$topLevel = @(Get-ChildItem -LiteralPath $WorkDir -Force)
if ($topLevel.Count -ne 1 -or -not $topLevel[0].PSIsContainer -or $topLevel[0].Name -cne 'CedarDSH-Desktop') {
  throw 'ZIP must contain exactly one CedarDSH-Desktop top-level directory'
}
$pkgRoot = Join-Path $WorkDir 'CedarDSH-Desktop'
$reparsePoints = @(
  @(
    Get-Item -LiteralPath $pkgRoot -Force
    Get-ChildItem -LiteralPath $pkgRoot -Recurse -Force
  ) | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
)
if ($reparsePoints.Count -gt 0) {
  throw "extracted package contains a reparse point before first launch: $($reparsePoints[0].FullName)"
}
$dshHome = Join-Path $pkgRoot 'dsh-home'
if (-not (Test-Path -LiteralPath $dshHome -PathType Container) -or @(Get-ChildItem -LiteralPath $dshHome -Force).Count -ne 0) {
  throw 'packaged dsh-home must exist and be completely empty before first launch'
}
$workspace = Join-Path $pkgRoot 'workspace'
if (-not (Test-Path -LiteralPath $workspace -PathType Container) -or @(Get-ChildItem -LiteralPath $workspace -Force).Count -ne 0) {
  throw 'packaged workspace must exist and be completely empty before first launch'
}
$exe = Join-Path $pkgRoot 'CedarDSH-Desktop.exe'
if (-not (Test-Path $exe)) { throw "extraction incomplete: $exe missing" }
$exeVersion = (Get-Item -LiteralPath $exe).VersionInfo
if ([string]$exeVersion.ProductName -cne 'CedarDSH Desktop' -or
  [string]$exeVersion.FileDescription -cne 'CedarDSH Desktop' -or
  [string]$exeVersion.OriginalFilename -cne 'CedarDSH-Desktop.exe' -or
  [string]$exeVersion.InternalName -cne 'CedarDSH-Desktop') {
  throw "EXE branding metadata is inconsistent: $($exeVersion | Select-Object ProductName, FileDescription, OriginalFilename, InternalName | ConvertTo-Json -Compress)"
}
$shellArchive = Join-Path $pkgRoot 'resources\app.asar'
if (Test-Path -LiteralPath $shellArchive) {
  throw 'packaged desktop shell must remain unpacked for in-place updates'
}
$shellRoot = Join-Path $pkgRoot 'resources\app'
if (-not (Test-Path -LiteralPath $shellRoot -PathType Container)) {
  throw 'extraction incomplete: unpacked desktop shell missing'
}
foreach ($shellFile in @(
  'package.json', 'main.js', 'startup-progress.js', 'launch-args.js', 'process-lifecycle.js', 'diagnostics.js',
  'update.js', 'update-install.js', 'update-helper.ps1', 'cedardsh.patch.yml', 'deepseek-mark.svg', 'icon.ico'
)) {
  if (-not (Test-Path -LiteralPath (Join-Path $shellRoot $shellFile) -PathType Leaf)) {
    throw "extraction incomplete: packaged desktop shell file missing: $shellFile"
  }
}
Write-Output ('[1/4] extraction OK: {0} files' -f (Get-ChildItem $pkgRoot -Recurse -File).Count)

# ── 2. manifest + node runtime ───────────────────────────────────────────────
$manifestPath = Join-Path $pkgRoot 'manifest.json'
if (-not (Test-Path $manifestPath)) { throw 'manifest.json missing' }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$semanticVersionPattern = '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
if ([string]$manifest.portableVersion -notmatch $semanticVersionPattern) { throw 'manifest has no valid portable version' }
if ([string]$manifest.dshVersion -notmatch $semanticVersionPattern) { throw 'manifest has no valid dsh version' }
if ($ExpectedPortableVersion -and [string]$manifest.portableVersion -cne $ExpectedPortableVersion) {
  throw "manifest portable version does not match the requested build: $($manifest.portableVersion) != $ExpectedPortableVersion"
}
if ($ExpectedDshVersion -and [string]$manifest.dshVersion -cne $ExpectedDshVersion) {
  throw "manifest dsh version does not match the requested build: $($manifest.dshVersion) != $ExpectedDshVersion"
}
if ([string]$manifest.name -cne 'CedarDSH Desktop') { throw "unexpected package name: $($manifest.name)" }
$ownedTopLevelEntries = @($manifest.ownedTopLevelEntries | ForEach-Object { [string]$_ })
if ($ownedTopLevelEntries.Count -eq 0 -or $ownedTopLevelEntries.Count -ne @($ownedTopLevelEntries | Sort-Object -Unique).Count) {
  throw 'manifest has no valid ownedTopLevelEntries list'
}
foreach ($entry in $ownedTopLevelEntries) {
  if ([string]::IsNullOrWhiteSpace($entry) -or [IO.Path]::GetFileName($entry) -cne $entry -or
    $entry -in @('.', '..', 'dsh-home', 'workspace', '.cedardsh-update')) {
    throw "manifest owns invalid or preserved top-level entry: $entry"
  }
}
$actualOwnedEntries = @(
  Get-ChildItem -LiteralPath $pkgRoot -Force |
    Where-Object { $_.Name -notin @('dsh-home', 'workspace') } |
    ForEach-Object Name |
    Sort-Object
)
if (Compare-Object @($ownedTopLevelEntries | Sort-Object) $actualOwnedEntries) {
  throw 'manifest ownedTopLevelEntries do not match the extracted program files'
}
if ([string]$exeVersion.ProductVersion -cne [string]$manifest.portableVersion -or
  [string]$exeVersion.FileVersion -cne [string]$manifest.portableVersion) {
  throw "EXE version metadata does not match portable $($manifest.portableVersion)"
}
if ([bool]$ExpectedDshSourceTag -ne [bool]$ExpectedDshSourceSha) {
  throw 'ExpectedDshSourceTag and ExpectedDshSourceSha must be supplied together'
}
$sourceKind = [string]$manifest.dshSource.kind
if ($sourceKind -ceq 'official-git-tag') {
  if ([string]$manifest.dshSource.repository -cne 'https://github.com/deepseek-ai/deepseek-harness' -or
    [string]$manifest.dshSource.tag -cne "dsh-v$($manifest.dshVersion)" -or
    [string]$manifest.dshSource.commit -cnotmatch '^[0-9a-f]{40}$' -or
    [string]$manifest.dshSource.packageManager -cnotmatch '^pnpm@\d+\.\d+\.\d+$' -or
    [int]$manifest.dshSource.packageCount -le 0 -or
    [int]$manifest.dshSource.runtimePackageCount -le 0 -or
    [int]$manifest.dshSource.runtimePackageCount -gt [int]$manifest.dshSource.packageCount -or
    [int]$manifest.dshSource.internalSnapshotCount -ne [int]$manifest.dshSource.runtimePackageCount -or
    [int]$manifest.dshSource.externalResolutionCount -lt 50 -or
    [string]$manifest.dshSource.provenanceSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]$manifest.dshSource.runtimeLockSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]$manifest.dshSource.runtimeResolutionsSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]$manifest.dshSource.internalRuntimeSnapshotsSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]$manifest.dshSource.consumerLockControlSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]$manifest.dshSource.consumerLockSha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'manifest has invalid official dsh source provenance'
  }
  if ($ExpectedDshSourceTag) {
    if ($ExpectedDshSourceSha -cnotmatch '^[0-9a-f]{40}$') { throw 'ExpectedDshSourceSha must be a lowercase 40-character commit' }
    if ([string]$manifest.dshSource.tag -cne $ExpectedDshSourceTag -or
      [string]$manifest.dshSource.commit -cne $ExpectedDshSourceSha) {
      throw 'manifest official dsh source provenance does not match the requested source'
    }
  }
} elseif ($sourceKind -ceq 'npm') {
  if ($ExpectedDshSourceTag) { throw 'manifest does not contain the requested official dsh source' }
  if ([string]$manifest.dshSource.package -cne '@deepseek-ai/dsh' -or
    [string]$manifest.dshSource.version -cne [string]$manifest.dshVersion) {
    throw 'manifest has invalid npm dsh source provenance'
  }
} else {
  throw "manifest has an unsupported dsh source: $($manifest.dshSource.kind)"
}
$expectedZipName = "CedarDSH-Desktop-win64-v$($manifest.portableVersion).zip"
if ((Split-Path -Leaf $ZipPath) -cne $expectedZipName) {
  throw "ZIP name does not match manifest portable version: expected $expectedZipName"
}
$nodeVer = & (Join-Path $pkgRoot 'runtime\node.exe') --version
if ($nodeVer.Trim() -ne $manifest.nodeVersion) { throw "node version mismatch: $($nodeVer.Trim()) != $($manifest.nodeVersion)" }
$pnpmManifest = Get-Content (Join-Path $pkgRoot 'runtime\node_modules\pnpm\package.json') -Raw | ConvertFrom-Json
$pnpmVer = (& (Join-Path $pkgRoot 'runtime\pnpm.cmd') --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $pnpmVer -cne [string]$manifest.pnpmVersion -or
  [string]$pnpmManifest.version -cne [string]$manifest.pnpmVersion -or
  [string]$manifest.pnpmPackageSha256 -cnotmatch '^[0-9a-f]{64}$') {
  throw "pinned plugin package manager mismatch: runtime $pnpmVer / package $($pnpmManifest.version) / manifest $($manifest.pnpmVersion)"
}
if ($manifest.updateFeed -ne 'https://github.com/maiziman/cedardsh-desktop/releases') { throw "unexpected update feed: $($manifest.updateFeed)" }
if ($manifest.startupProfileLinkCount -le 0) { throw 'manifest has no startup profile component total' }
$modelCapabilitiesRoot = Join-Path $pkgRoot 'app\node_modules\@maiziman\dsh-model-capabilities'
if (Test-Path -LiteralPath $modelCapabilitiesRoot) { throw 'pure portable package unexpectedly contains the optional capability plugin' }
$desktopUpdateRoot = Join-Path $pkgRoot 'app\node_modules\@cedardsh\desktop-update'
foreach ($pluginFile in @('package.json', 'lib\index.js', 'lib\client.js')) {
  if (-not (Test-Path -LiteralPath (Join-Path $desktopUpdateRoot $pluginFile) -PathType Leaf)) {
    throw "CedarDSH desktop update package file is missing: $pluginFile"
  }
}
$packageManagerState = @(
  (Join-Path $pkgRoot 'app\package.json'),
  (Join-Path $pkgRoot 'app\pnpm-lock.yaml'),
  (Join-Path $pkgRoot 'app\pnpm-workspace.yaml'),
  (Join-Path $pkgRoot 'app\node_modules\.modules.yaml'),
  (Join-Path $pkgRoot 'app\node_modules\.pnpm-workspace-state-v1.json'),
  (Join-Path $pkgRoot 'app\node_modules\.pnpm')
)
foreach ($statePath in $packageManagerState) {
  if (Test-Path -LiteralPath $statePath) { throw "portable package contains build-time package-manager state: $statePath" }
}
Assert-DshPortableBuildMetadataClean (Join-Path $pkgRoot 'app\node_modules')
$dshBin = Join-Path $pkgRoot 'app\node_modules\@deepseek-ai\dsh\lib\bin.js'
if (-not (Test-Path -LiteralPath $dshBin -PathType Leaf)) { throw 'official dsh CLI entry is missing' }
$dshCliVersion = (& (Join-Path $pkgRoot 'runtime\node.exe') $dshBin --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $dshCliVersion -cne [string]$manifest.dshVersion) {
  throw "official dsh CLI version mismatch: $dshCliVersion != $($manifest.dshVersion)"
}
$readme = Get-Content (Join-Path $pkgRoot 'README.txt') -Raw
$versionLine = "版本：portable $($manifest.portableVersion) / dsh $($manifest.dshVersion) / Node $($manifest.nodeVersion) / Electron $($manifest.electronVersion)"
if (-not $readme.Contains($versionLine)) { throw 'README.txt does not report the manifest component versions' }
$noticesPath = Join-Path $pkgRoot 'THIRD_PARTY_NOTICES.md'
if (-not (Test-Path $noticesPath -PathType Leaf)) { throw 'THIRD_PARTY_NOTICES.md missing' }
$notices = Get-Content $noticesPath -Raw
if (-not $notices.Contains('Copyright (c) 2026 DeepSeek') -or -not $notices.Contains('apps/web/public/favicon.svg')) {
  throw 'DeepSeek whale mark source or license notice missing'
}
Write-Output ('[2/4] manifest OK: dsh {0} / node {1} / electron {2} / source {3}' -f $manifest.dshVersion, $manifest.nodeVersion, $manifest.electronVersion, $manifest.dshSource.kind)

# ── 3. smoke: boot the app, capture the UI ───────────────────────────────────
$smoke = Join-Path $WorkDir 'smoke.png'
$startupSmoke = Join-Path $WorkDir 'startup-progress.png'
$startupStatePath = Join-Path $WorkDir 'startup-progress-state.json'
$saved = @{
  DSH_SMOKE = $env:DSH_SMOKE
  DSH_SMOKE_OUT = $env:DSH_SMOKE_OUT
  DSH_SMOKE_PROGRESS_OUT = $env:DSH_SMOKE_PROGRESS_OUT
  DSH_SMOKE_PROGRESS_STATE_OUT = $env:DSH_SMOKE_PROGRESS_STATE_OUT
  DSH_SMOKE_DELAY_MS = $env:DSH_SMOKE_DELAY_MS
}
try {
  $env:DSH_SMOKE = '1'
  $env:DSH_SMOKE_OUT = $smoke
  $env:DSH_SMOKE_PROGRESS_OUT = $startupSmoke
  $env:DSH_SMOKE_PROGRESS_STATE_OUT = $startupStatePath
  $env:DSH_SMOKE_DELAY_MS = '4000'
  $proc = Start-Process -FilePath $exe -WorkingDirectory $pkgRoot -PassThru
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
    throw 'smoke timed out after 270s'
  }
  if ($proc.ExitCode -ne 0) { throw "smoke exited $($proc.ExitCode); see $pkgRoot\dsh-home\logs\server.log" }
  $img = Get-Item $smoke
  if ($img.Length -lt 10240) { throw "screenshot suspiciously small: $($img.Length) bytes" }
  $startupImg = Get-Item $startupSmoke
  if ($startupImg.Length -lt 10240) { throw "startup screenshot suspiciously small: $($startupImg.Length) bytes" }
  if (-not (Test-Path -LiteralPath $startupStatePath -PathType Leaf)) { throw 'startup progress evidence was not written' }
  $startupState = Get-Content -LiteralPath $startupStatePath -Raw | ConvertFrom-Json
  if (-not [bool]$startupState.firstRun -or
    [int]$startupState.expectedLinks -ne [int]$manifest.startupProfileLinkCount -or
    [int]$startupState.measuredLinks -le 0 -or
    [string]$startupState.rendered.key -cne 'links' -or
    [int]$startupState.rendered.linked -le 0 -or
    [int]$startupState.rendered.total -ne [int]$manifest.startupProfileLinkCount -or
    -not ([string]$startupState.rendered.detail).Contains("$($startupState.rendered.linked)") -or
    -not ([string]$startupState.rendered.detail).Contains("$($startupState.rendered.total)")) {
    throw "startup progress did not render measured package-owned component evidence: $($startupState | ConvertTo-Json -Depth 5 -Compress)"
  }
  $verificationArtifacts = Join-Path $root '.build'
  New-Item -ItemType Directory -Force -Path $verificationArtifacts | Out-Null
  Copy-Item -LiteralPath $smoke -Destination (Join-Path $verificationArtifacts 'smoke.png') -Force
  Copy-Item -LiteralPath $startupSmoke -Destination (Join-Path $verificationArtifacts 'startup-progress.png') -Force
  Copy-Item -LiteralPath $startupStatePath -Destination (Join-Path $verificationArtifacts 'startup-progress-state.json') -Force
  Write-Output ('[3/4] smoke OK: exit 0, startup {0} KB, UI {1} KB' -f [math]::Round($startupImg.Length / 1KB), [math]::Round($img.Length / 1KB))
} finally {
  $env:DSH_SMOKE = $saved.DSH_SMOKE
  $env:DSH_SMOKE_OUT = $saved.DSH_SMOKE_OUT
  $env:DSH_SMOKE_PROGRESS_OUT = $saved.DSH_SMOKE_PROGRESS_OUT
  $env:DSH_SMOKE_PROGRESS_STATE_OUT = $saved.DSH_SMOKE_PROGRESS_STATE_OUT
  $env:DSH_SMOKE_DELAY_MS = $saved.DSH_SMOKE_DELAY_MS
}

# ── 4. first-run behavior: URL announced + profile auto-init ─────────────────
$log = Get-Content (Join-Path $pkgRoot 'dsh-home\logs\server.log') -Raw
if ($log -notmatch 'dsh web: http://') { throw 'server never announced its URL' }
if (-not (Test-Path (Join-Path $pkgRoot 'dsh-home\profiles\web'))) { throw 'web profile was not initialized' }
$profileModules = Join-Path $pkgRoot 'dsh-home\profiles\node_modules'
if (-not (Test-Path (Join-Path $profileModules '@deepseek-ai\dsh'))) { throw 'installation fallback not prepared' }
if (-not (Test-Path (Join-Path $profileModules '@cedardsh\desktop-update'))) { throw 'desktop update client link not prepared' }
$actualProfileLinks = Get-ProfileLinkCount $profileModules (Join-Path $pkgRoot 'app\node_modules')
if ($actualProfileLinks -ne $manifest.startupProfileLinkCount) {
  throw "startup component total mismatch: $actualProfileLinks != $($manifest.startupProfileLinkCount)"
}
Write-Output "[4/4] first-run OK: server URL announced, web profile initialized, $actualProfileLinks component links"

Write-Output '=== VERIFY PASSED ==='
if (-not $Keep) { Remove-Item -Recurse -Force $WorkDir }
