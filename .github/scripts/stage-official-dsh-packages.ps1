# Stage the exact tarballs created by the official DeepSeek Harness release
# scripts and bind every byte to its official tag, commit, and package identity.
#requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SourceDirectory,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [Parameter(Mandatory)][string]$ExpectedVersion,
  [Parameter(Mandatory)][string]$ExpectedSourceTag,
  [Parameter(Mandatory)][string]$ExpectedSourceSha
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'official-dsh-package-input.ps1')

$source = (Get-Item -LiteralPath $SourceDirectory -ErrorAction Stop).FullName
if (-not (Get-Item -LiteralPath $SourceDirectory).PSIsContainer) { throw 'official source is not a directory' }
if ($ExpectedSourceSha -cnotmatch '^[0-9a-f]{40}$') { throw "invalid expected source SHA: $ExpectedSourceSha" }
if (Test-Path -LiteralPath $OutputDirectory) { throw "staging output already exists: $OutputDirectory" }

Push-Location $source
try {
  $head = (& git rev-parse HEAD | Out-String).Trim()
  $tagCommit = (& git rev-list -n 1 "refs/tags/$ExpectedSourceTag" | Out-String).Trim()
  $trackedChanges = (& git status --porcelain --untracked-files=no | Out-String).Trim()
  $rootManifest = Get-Content -LiteralPath (Join-Path $source 'package.json') -Raw | ConvertFrom-Json
  $cliManifest = Get-Content -LiteralPath (Join-Path $source 'apps/cli/package.json') -Raw | ConvertFrom-Json
} finally {
  Pop-Location
}
if ($head -cne $ExpectedSourceSha -or $tagCommit -cne $ExpectedSourceSha) {
  throw "official checkout does not match $ExpectedSourceTag at $ExpectedSourceSha"
}
if ($trackedChanges) { throw "official build changed tracked source files:`n$trackedChanges" }
if ([string]$rootManifest.version -cne $ExpectedVersion -or [string]$cliManifest.version -cne $ExpectedVersion) {
  throw 'official root and CLI versions do not match the selected tag version'
}
if ([string]$rootManifest.packageManager -cnotmatch '^pnpm@(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
  throw "official source has an unsupported package manager: $($rootManifest.packageManager)"
}
$allowBuilds = Read-DshOfficialAllowBuildsPolicy -WorkspacePath (Join-Path $source 'pnpm-workspace.yaml')
$patchedDependencies = Read-DshOfficialPatchedDependencies -WorkspacePath (Join-Path $source 'pnpm-workspace.yaml')

$families = [ordered]@{
  dsh = (Join-Path $source 'dist/npm')
  vendor = (Join-Path $source 'dist/npm-vendor')
  landlock = (Join-Path $source 'dist/npm-landlock')
}
$allRecords = @()
$seenNames = @{}
foreach ($family in $families.Keys) {
  $sourcePackages = @(Get-ChildItem -LiteralPath $families[$family] -File -Filter '*.tgz' | Sort-Object Name)
  if ($sourcePackages.Count -eq 0) { throw "official release produced no $family tarballs" }
  $familyTarget = Join-Path $OutputDirectory $family
  New-Item -ItemType Directory -Path $familyTarget -Force | Out-Null
  foreach ($archive in $sourcePackages) {
    $identity = Read-DshPackedPackageIdentity -ArchivePath $archive.FullName
    if ($seenNames.ContainsKey($identity.Name)) { throw "official release produced duplicate package $($identity.Name)" }
    $seenNames[$identity.Name] = $true
    if ($family -ceq 'dsh' -and $identity.Version -cne $ExpectedVersion) {
      throw "official dsh package $($identity.Name) has version $($identity.Version), expected $ExpectedVersion"
    }
    $target = Join-Path $familyTarget $archive.Name
    Copy-Item -LiteralPath $archive.FullName -Destination $target
    $relative = "$family/$($archive.Name)"
    $allRecords += [pscustomobject][ordered]@{
      relativePath = $relative
      name = $identity.Name
      version = $identity.Version
      size = (Get-Item -LiteralPath $target).Length
      sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
}
if (@($allRecords | Where-Object { $_.name -ceq '@deepseek-ai/dsh' }).Count -ne 1) {
  throw 'official release output must contain exactly one @deepseek-ai/dsh package'
}

$orderedRecords = @($allRecords | Sort-Object relativePath)
$orderedAllowBuilds = [ordered]@{}
foreach ($name in @($allowBuilds.Keys | Sort-Object)) { $orderedAllowBuilds[$name] = [bool]$allowBuilds[$name] }
$runtimeLockRoot = Join-Path $OutputDirectory 'runtime-lock'
New-Item -ItemType Directory -Path $runtimeLockRoot -Force | Out-Null
foreach ($name in @('package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml')) {
  $sourceFile = Join-Path $source $name
  if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { throw "official source has no $name" }
  Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $runtimeLockRoot $name)
}
$orderedPatchedDependencies = [ordered]@{}
foreach ($name in @($patchedDependencies.Keys | Sort-Object)) {
  $relative = [string]$patchedDependencies[$name]
  $patchSource = Join-Path $source $relative
  if (-not (Test-Path -LiteralPath $patchSource -PathType Leaf)) { throw "official source patch is missing: $relative" }
  $patchTarget = Join-Path $runtimeLockRoot $relative
  New-Item -ItemType Directory -Path (Split-Path $patchTarget -Parent) -Force | Out-Null
  Copy-Item -LiteralPath $patchSource -Destination $patchTarget
  $orderedPatchedDependencies[$name] = $relative
}
$runtimeLockRecords = @(Get-ChildItem -LiteralPath $runtimeLockRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
  [pscustomobject][ordered]@{
    relativePath = Get-DshPackageRelativePath -Root $runtimeLockRoot -Path $_.FullName
    size = $_.Length
    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
})
$provenance = [ordered]@{
  schemaVersion = 3
  kind = 'official-git-tag'
  repository = 'https://github.com/deepseek-ai/deepseek-harness'
  sourceTag = $ExpectedSourceTag
  sourceSha = $ExpectedSourceSha
  dshVersion = $ExpectedVersion
  packageManager = [string]$rootManifest.packageManager
  allowBuilds = $orderedAllowBuilds
  patchedDependencies = $orderedPatchedDependencies
  runtimeLockFiles = $runtimeLockRecords
  packageCount = $orderedRecords.Count
  packages = $orderedRecords
}
$provenance | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'provenance.json') -Encoding utf8
($orderedRecords | ForEach-Object { "$($_.sha256)  $($_.relativePath)" }) -join "`n" |
  Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding utf8 -NoNewline

$verified = Get-DshOfficialPackageInput `
  -Directory $OutputDirectory `
  -ExpectedVersion $ExpectedVersion `
  -ExpectedSourceTag $ExpectedSourceTag `
  -ExpectedSourceSha $ExpectedSourceSha `
  -AllowUnfinalized
Write-Output "staged $($verified.Packages.Count) verified official package archives from $ExpectedSourceTag ($ExpectedSourceSha)"
