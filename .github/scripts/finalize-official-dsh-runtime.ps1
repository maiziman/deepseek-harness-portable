# Finalize a staged official package set with one deterministic Windows x64
# consumer lock derived from the selected source commit's production graph.
#requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SourceDirectory,
  [Parameter(Mandatory)][string]$PackageDirectory,
  [Parameter(Mandatory)][string]$ExpectedVersion,
  [Parameter(Mandatory)][string]$ExpectedSourceTag,
  [Parameter(Mandatory)][string]$ExpectedSourceSha,
  [Parameter(Mandatory)][string]$NodePath,
  [Parameter(Mandatory)][string]$PnpmCjsPath,
  [Parameter(Mandatory)][string]$StoreDirectory,
  [Parameter(Mandatory)][string]$CacheDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'official-dsh-package-input.ps1')
. (Join-Path $PSScriptRoot 'pnpm-build-policy.ps1')

$source = (Get-Item -LiteralPath $SourceDirectory -ErrorAction Stop).FullName
$packageRoot = (Get-Item -LiteralPath $PackageDirectory -ErrorAction Stop).FullName
$node = (Get-Item -LiteralPath $NodePath -ErrorAction Stop).FullName
$pnpm = (Get-Item -LiteralPath $PnpmCjsPath -ErrorAction Stop).FullName
$store = [IO.Path]::GetFullPath($StoreDirectory)
$cache = [IO.Path]::GetFullPath($CacheDirectory)
if ($ExpectedSourceSha -cnotmatch '^[0-9a-f]{40}$') { throw "invalid expected source SHA: $ExpectedSourceSha" }

Push-Location $source
try {
  $head = (& git rev-parse HEAD | Out-String).Trim()
  $tagCommit = (& git rev-list -n 1 "refs/tags/$ExpectedSourceTag" | Out-String).Trim()
  $trackedChanges = (& git status --porcelain --untracked-files=no | Out-String).Trim()
} finally {
  Pop-Location
}
if ($head -cne $ExpectedSourceSha -or $tagCommit -cne $ExpectedSourceSha) {
  throw 'runtime finalization source does not match the selected official tag and commit'
}
if ($trackedChanges) { throw "official source has tracked changes before runtime finalization:`n$trackedChanges" }

$input = Get-DshOfficialPackageInput `
  -Directory $packageRoot `
  -ExpectedVersion $ExpectedVersion `
  -ExpectedSourceTag $ExpectedSourceTag `
  -ExpectedSourceSha $ExpectedSourceSha `
  -AllowUnfinalized
if ([int]$input.Provenance.schemaVersion -ne 3) { throw 'official package input was already finalized' }
$runtimePackages = @($input.InternalRuntimePackages)

$consumerRoot = Join-Path $packageRoot 'consumer'
if (Test-Path -LiteralPath $consumerRoot) { throw "consumer template already exists: $consumerRoot" }
$manifestListPath = Join-Path $packageRoot '.runtime-manifests.tmp.json'
$derivedPath = Join-Path $packageRoot '.runtime-resolutions.tmp.json'
foreach ($temporaryPath in @($manifestListPath, $derivedPath)) {
  if (Test-Path -LiteralPath $temporaryPath) { throw "runtime finalization temporary path already exists: $temporaryPath" }
}

try {
  @($runtimePackages | ForEach-Object { $_.Manifest }) | ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $manifestListPath -Encoding utf8
  & $node (Join-Path $PSScriptRoot 'derive-official-runtime-lock.mjs') `
    --source-root $source `
    --runtime-manifests $manifestListPath `
    --output $derivedPath
  if ($LASTEXITCODE -ne 0) { throw "official runtime resolution derivation failed (exit $LASTEXITCODE)" }
  $derived = Get-Content -LiteralPath $derivedPath -Raw | ConvertFrom-Json
  if ([int]$derived.internalPackageCount -ne $runtimePackages.Count -or
    [int]$derived.externalResolutionCount -lt 50) {
    throw 'official runtime resolution derivation returned inconsistent counts'
  }

  New-Item -ItemType Directory -Path $consumerRoot | Out-Null
  $dependencies = [ordered]@{}
  foreach ($package in $runtimePackages) {
    $dependencies[[string]$package.Name] = "file:../$($package.RelativePath)"
  }
  foreach ($property in @($derived.consumerPeerPins.PSObject.Properties | Sort-Object Name)) {
    if ($dependencies.Contains([string]$property.Name)) { throw "consumer peer pin conflicts with internal package $($property.Name)" }
    $dependencies[[string]$property.Name] = [string]$property.Value
  }
  [ordered]@{
    name = 'deepseek-harness-portable-official-runtime'
    version = '0.0.0'
    private = $true
    packageManager = [string]$input.PackageManager
    dependencies = $dependencies
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $consumerRoot 'package.json') -Encoding utf8

  $subprocessName = '@deepseek-ai/dsh-subprocess-local'
  $subprocessPackage = @($runtimePackages | Where-Object { $_.Name -ceq $subprocessName })
  if ($subprocessPackage.Count -ne 1) { throw "official runtime closure must contain exactly one $subprocessName package" }
  $subprocessSelector = Get-DshPnpmFileBuildSelector `
    -PackageName $subprocessName `
    -TargetDirectory $consumerRoot `
    -ArchivePath ([string]$subprocessPackage[0].File)
  $workspaceLines = @('allowBuilds:')
  $subprocessPolicyCount = 0
  foreach ($name in @($input.AllowBuilds.Keys | Sort-Object)) {
    $selector = [string]$name
    if ($selector.StartsWith("${subprocessName}@file:", [StringComparison]::Ordinal)) {
      $selector = $subprocessSelector
      $subprocessPolicyCount++
    }
    $enabled = ([bool]$input.AllowBuilds[$name]).ToString().ToLowerInvariant()
    $workspaceLines += "  $((ConvertTo-Json $selector -Compress)): $enabled"
  }
  if ($subprocessPolicyCount -ne 1) { throw 'official lifecycle policy has no exact subprocess file selector' }
  if ($input.PatchedDependencies.Count -gt 0) {
    $workspaceLines += 'patchedDependencies:'
    foreach ($name in @($input.PatchedDependencies.Keys | Sort-Object)) {
      $relative = [string]$input.PatchedDependencies[$name]
      $workspaceLines += "  $((ConvertTo-Json ([string]$name) -Compress)): ../runtime-lock/$relative"
    }
  }
  $overrides = [ordered]@{}
  foreach ($package in @($input.Packages | Sort-Object Name)) {
    $overrides[[string]$package.Name] = "file:../$($package.RelativePath)"
  }
  foreach ($property in @($derived.consumerOverrides.PSObject.Properties | Sort-Object Name)) {
    $name = [string]$property.Name
    if ($overrides.Contains($name)) { throw "consumer override conflicts with staged official package $name" }
    $value = [string]$property.Value
    if (-not $value -or $value -match '[\r\n]') { throw "consumer override has an invalid value: $name" }
    $overrides[$name] = $value
  }
  $workspaceLines += 'overrides:'
  foreach ($name in @($overrides.Keys | Sort-Object)) {
    $workspaceLines += "  $((ConvertTo-Json ([string]$name) -Compress)): $((ConvertTo-Json ([string]$overrides[$name]) -Compress))"
  }
  ($workspaceLines -join "`n") | Set-Content -LiteralPath (Join-Path $consumerRoot 'pnpm-workspace.yaml') -Encoding utf8

  New-Item -ItemType Directory -Path $store, $cache -Force | Out-Null
  $savedCi = $env:CI
  try {
    $env:CI = 'true'
    & $node $pnpm `
      --dir $consumerRoot install `
      --lockfile-only `
      --ignore-scripts `
      --no-frozen-lockfile `
      --config.minimum-release-age=0 `
      --registry=https://registry.npmjs.org/ `
      --store-dir $store `
      --cache-dir $cache `
      --reporter=append-only
    if ($LASTEXITCODE -ne 0) { throw "canonical consumer lock generation failed (exit $LASTEXITCODE)" }
  } finally {
    $env:CI = $savedCi
  }
  if (Test-Path -LiteralPath (Join-Path $consumerRoot 'node_modules')) {
    throw 'lock-only consumer generation unexpectedly created node_modules'
  }

  & $node (Join-Path $PSScriptRoot 'derive-official-runtime-lock.mjs') `
    --source-root $source `
    --runtime-manifests $manifestListPath `
    --candidate-lock (Join-Path $consumerRoot 'pnpm-lock.yaml') `
    --normalize-candidate-lock `
    --output $derivedPath
  if ($LASTEXITCODE -ne 0) { throw "canonical consumer lock verification failed (exit $LASTEXITCODE)" }
  $derived = Get-Content -LiteralPath $derivedPath -Raw | ConvertFrom-Json

  $internalRecords = @($runtimePackages | Sort-Object Name | ForEach-Object {
    [pscustomobject][ordered]@{
      name = [string]$_.Name
      version = [string]$_.Version
      relativePath = [string]$_.RelativePath
      sha256 = [string]$_.Sha256
    }
  })
  $consumerFiles = @(Get-ChildItem -LiteralPath $consumerRoot -File | Sort-Object Name | ForEach-Object {
    [pscustomobject][ordered]@{
      relativePath = [string]$_.Name
      size = [int64]$_.Length
      sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  })
  if ($consumerFiles.Count -ne 3) { throw 'canonical consumer template must contain exactly three files' }

  $old = $input.Provenance
  $provenance = [ordered]@{
    schemaVersion = 4
    kind = [string]$old.kind
    repository = [string]$old.repository
    sourceTag = [string]$old.sourceTag
    sourceSha = [string]$old.sourceSha
    dshVersion = [string]$old.dshVersion
    packageManager = [string]$old.packageManager
    target = 'win32-x64'
    allowBuilds = $old.allowBuilds
    patchedDependencies = $old.patchedDependencies
    runtimeLockFiles = $old.runtimeLockFiles
    runtimeGraphDerivation = 'official-lock-importers-prod-optional-required-peers'
    runtimeInternalPackageCount = $internalRecords.Count
    runtimeInternalPackages = $internalRecords
    internalSnapshotCount = [int]$derived.internalSnapshotCount
    internalRuntimeSnapshotsSha256 = [string]$derived.internalRuntimeSnapshotsSha256
    internalRuntimeSnapshots = $derived.internalRuntimeSnapshots
    consumerLockControlSha256 = [string]$derived.consumerLockControlSha256
    consumerLockControl = $derived.consumerLockControl
    externalResolutionCount = [int]$derived.externalResolutionCount
    runtimeResolutionsSha256 = [string]$derived.runtimeResolutionsSha256
    runtimeResolutions = $derived.runtimeResolutions
    consumerPeerPins = $derived.consumerPeerPins
    excludedWindowsOptionalPackages = $derived.excludedWindowsOptionalPackages
    consumerOverrideCount = $overrides.Count
    consumerFiles = $consumerFiles
    packageCount = [int]$old.packageCount
    packages = $old.packages
  }
  $provenance | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $packageRoot 'provenance.json') -Encoding utf8
} finally {
  foreach ($temporaryPath in @($manifestListPath, $derivedPath)) {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force }
  }
}

$verified = Get-DshOfficialPackageInput `
  -Directory $packageRoot `
  -ExpectedVersion $ExpectedVersion `
  -ExpectedSourceTag $ExpectedSourceTag `
  -ExpectedSourceSha $ExpectedSourceSha
Write-Output "finalized $($verified.InternalRuntimePackages.Count) internal packages and $($verified.ExternalRuntimeResolutions.Count) external resolutions for Windows x64"
