# Real pnpm fixture proving that the lifecycle-script gate rejects an unlisted
# postinstall and accepts explicit allow/deny decisions.
#requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$NodePath,
  [Parameter(Mandatory)][string]$PnpmCjsPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'pnpm-build-policy.ps1')

$node = (Get-Item -LiteralPath $NodePath -ErrorAction Stop).FullName
$pnpm = (Get-Item -LiteralPath $PnpmCjsPath -ErrorAction Stop).FullName
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-pnpm-policy-' + [guid]::NewGuid().ToString('N'))

function Set-TestWorkspacePolicy {
  param(
    [Parameter(Mandatory)][string]$Value,
    [string]$Selector = 'dsh-pnpm-build-fixture'
  )
  @(
    'allowBuilds:'
    "  '$Selector': $Value"
  ) -join "`n" | Set-Content -LiteralPath (Join-Path $testRoot 'consumer\pnpm-workspace.yaml') -Encoding utf8
}

function Install-TestConsumer {
  $consumer = Join-Path $testRoot 'consumer'
  $store = Join-Path $testRoot 'store'
  & $node $pnpm --dir $consumer install --node-linker=hoisted --reporter=append-only --no-frozen-lockfile --store-dir $store
  if ($LASTEXITCODE -ne 0) { throw "fixture pnpm install failed (exit $LASTEXITCODE)" }
}

function Reset-TestInstall {
  foreach ($path in @('consumer\node_modules', 'consumer\pnpm-lock.yaml', 'store')) {
    $target = Join-Path $testRoot $path
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
  }
  $marker = Join-Path $testRoot 'consumer\built.txt'
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
}

New-Item -ItemType Directory -Path (Join-Path $testRoot 'package'), (Join-Path $testRoot 'consumer') -Force | Out-Null
try {
  [ordered]@{
    name = 'dsh-pnpm-build-fixture'
    version = '1.0.0'
    scripts = [ordered]@{ postinstall = 'node postinstall.cjs' }
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $testRoot 'package\package.json') -Encoding utf8
  "require('node:fs').writeFileSync(require('node:path').join(__dirname, '..', '..', 'built.txt'), 'built')" |
    Set-Content -LiteralPath (Join-Path $testRoot 'package\postinstall.cjs') -Encoding utf8
  $archive = Join-Path $testRoot 'dsh-pnpm-build-fixture-1.0.0.tgz'
  & tar -czf $archive -C $testRoot package
  if ($LASTEXITCODE -ne 0) { throw 'fixture archive creation failed' }
  $expectedSelector = 'dsh-pnpm-build-fixture@file:../dsh-pnpm-build-fixture-1.0.0.tgz'
  $actualSelector = Get-DshPnpmFileBuildSelector `
    -PackageName 'dsh-pnpm-build-fixture' `
    -TargetDirectory (Join-Path $testRoot 'consumer') `
    -ArchivePath $archive
  if ($actualSelector -cne $expectedSelector) { throw "file build selector mismatch: $actualSelector" }
  Write-Output 'PASS file lifecycle selector matches pnpm same-volume normalization'
  [ordered]@{
    name = 'dsh-pnpm-build-policy-consumer'
    version = '1.0.0'
    private = $true
    dependencies = [ordered]@{ 'dsh-pnpm-build-fixture' = ([Uri]$archive).AbsoluteUri }
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $testRoot 'consumer\package.json') -Encoding utf8

  Set-TestWorkspacePolicy -Value 'false'
  Install-TestConsumer
  if (Test-Path -LiteralPath (Join-Path $testRoot 'consumer\built.txt')) { throw 'explicitly denied fixture unexpectedly ran postinstall' }
  Assert-DshPnpmBuildScriptsComplete -NodePath $node -PnpmCjsPath $pnpm -TargetDirectory (Join-Path $testRoot 'consumer')
  Write-Output 'PASS explicitly denied lifecycle script is reviewed and not executed'

  Reset-TestInstall
  Set-Content -LiteralPath (Join-Path $testRoot 'consumer\pnpm-workspace.yaml') `
    -Value "strictDepBuilds: false`nallowBuilds:`n  unrelated-fixture: false" `
    -Encoding utf8
  Install-TestConsumer
  $rejected = $false
  try {
    Assert-DshPnpmBuildScriptsComplete -NodePath $node -PnpmCjsPath $pnpm -TargetDirectory (Join-Path $testRoot 'consumer')
  } catch {
    if ($_.Exception.Message -notmatch 'dsh-pnpm-build-fixture') { throw }
    Write-Output 'PASS unlisted lifecycle script is rejected after pnpm install'
    $rejected = $true
  }
  if (-not $rejected) { throw 'unlisted lifecycle script passed the fail-closed gate' }

  Reset-TestInstall
  Set-TestWorkspacePolicy -Value 'true' -Selector $expectedSelector
  Install-TestConsumer
  if (-not (Test-Path -LiteralPath (Join-Path $testRoot 'consumer\built.txt'))) { throw 'explicitly allowed fixture did not run postinstall' }
  Assert-DshPnpmBuildScriptsComplete -NodePath $node -PnpmCjsPath $pnpm -TargetDirectory (Join-Path $testRoot 'consumer')
  Write-Output 'PASS explicitly allowed lifecycle script runs and passes the gate'

  $metadataFixture = Join-Path $testRoot 'metadata-fallback'
  New-Item -ItemType Directory -Path (Join-Path $metadataFixture 'node_modules') -Force | Out-Null
  '{"allowBuilds":{"reviewed":false},"pendingBuilds":["reviewed@1.0.0"]}' | Set-Content -LiteralPath (Join-Path $metadataFixture 'node_modules\.modules.yaml') -Encoding utf8
  Assert-DshPnpmPendingBuildsReviewed -TargetDirectory $metadataFixture
  '{"allowBuilds":{"reviewed":false},"pendingBuilds":["unreviewed@1.0.0"]}' | Set-Content -LiteralPath (Join-Path $metadataFixture 'node_modules\.modules.yaml') -Encoding utf8
  $metadataRejected = $false
  try {
    Assert-DshPnpmPendingBuildsReviewed -TargetDirectory $metadataFixture
  } catch {
    if ($_.Exception.Message -notmatch 'unreviewed@1.0.0') { throw }
    $metadataRejected = $true
  }
  if (-not $metadataRejected) { throw 'module metadata fallback accepted a pending lifecycle script' }
  Write-Output 'PASS module metadata fallback accepts only reviewed pending builds'
} finally {
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\', [char]'/')
  $resolved = [IO.Path]::GetFullPath($testRoot)
  if (-not $resolved.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path $resolved -Leaf) -cnotlike 'dsh-pnpm-policy-*') {
    throw "refusing to clean unexpected test directory: $resolved"
  }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
