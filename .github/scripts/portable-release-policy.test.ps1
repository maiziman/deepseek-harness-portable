#requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'portable-release-policy.ps1')

$script:nextAssetId = 1
function New-TestAsset {
  param([Parameter(Mandatory)][string]$Name, [string]$State = 'uploaded')
  $id = $script:nextAssetId
  $script:nextAssetId++
  return [pscustomobject]@{
    digest = 'sha256:' + ('a' * 64)
    id = $id
    name = $Name
    size = 1024
    state = $State
  }
}

function New-TestRelease {
  param(
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$ZipVersion,
    [string]$AssetPrefix = 'CedarDSH-Desktop',
    [string]$Body = '',
    [bool]$Draft = $false,
    [bool]$Prerelease = $false,
    [string]$Commit = '1111111111111111111111111111111111111111'
  )
  return [pscustomobject]@{
    assets = @(
      (New-TestAsset -Name "$AssetPrefix-win64-v$ZipVersion.zip")
      (New-TestAsset -Name 'SHA256SUMS.txt')
    )
    body = $Body
    draft = $Draft
    prerelease = $Prerelease
    tag_name = $Tag
    target_commitish = $Commit
  }
}

function Assert-Equal {
  param([object]$Expected, [object]$Actual, [Parameter(Mandatory)][string]$Message)
  if ([string]$Expected -cne [string]$Actual) { throw "$Message (expected '$Expected', found '$Actual')" }
}

function Assert-Throws {
  param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Pattern)
  try { & $Action } catch {
    if ([string]$_.Exception.Message -like $Pattern) { return }
    throw "unexpected failure: $($_.Exception.Message)"
  }
  throw "expected failure matching $Pattern"
}

$uniqueHighest = Get-DshUniqueHighestSemverRecord -Records @(
  [pscustomobject]@{ Parsed = [System.Management.Automation.SemanticVersion]::Parse('1.0.0'); Tag = 'v1.0.0' }
  [pscustomobject]@{ Parsed = [System.Management.Automation.SemanticVersion]::Parse('1.0.1'); Tag = 'v1.0.1' }
) -Description 'fixture versions'
Assert-Equal 'v1.0.1' $uniqueHighest.Tag 'unique highest semantic version must be selected'
Assert-Throws -Pattern '*ambiguous highest semantic-version precedence*' -Action {
  Get-DshUniqueHighestSemverRecord -Records @(
    [pscustomobject]@{ Parsed = [System.Management.Automation.SemanticVersion]::Parse('1.0.0+first'); Tag = 'v1.0.0+first' }
    [pscustomobject]@{ Parsed = [System.Management.Automation.SemanticVersion]::Parse('1.0.0+second'); Tag = 'v1.0.0+second' }
  ) -Description 'fixture build metadata' | Out-Null
}
Write-Output 'PASS highest semantic-version selection rejects build-metadata ambiguity'

$legacy100 = New-TestRelease -Tag 'v1.0.0' -ZipVersion '0.1.1-rc.2' -AssetPrefix 'DeepSeek-Harness'
$legacy110 = New-TestRelease -Tag 'v1.1.0' -ZipVersion '0.1.1-rc.2' -AssetPrefix 'DeepSeek-Harness'
$legacy = New-TestRelease -Tag 'v1.2.0' -ZipVersion '0.1.1-rc.2' -AssetPrefix 'DeepSeek-Harness'
$legacyCompatibility = Get-DshCompletePortableReleases -Releases @($legacy100, $legacy110, $legacy)
Assert-Equal 3 $legacyCompatibility.Count 'all three published migration Releases must remain readable'
Write-Output 'PASS v1.0.0, v1.1.0, and v1.2.0 keep their exact historical ZIP identity'

$allocation = Resolve-DshPortableReleasePolicy -Releases @($legacy) -DshVersion '0.1.2-alpha.1'
Assert-Equal $false $allocation.AlreadyPackaged 'legacy Release must remain only a version floor'
Assert-Equal '1.2.1' $allocation.PortableVersion 'legacy v1.2.0 must allocate the next portable patch'
Assert-Equal 'v1.2.1' $allocation.ReleaseTag 'automatic Releases must join the v* family'
Assert-Equal 'CedarDSH-Desktop-win64-v1.2.1.zip' $allocation.AssetName 'ZIP must match the portable tag'
Write-Output 'PASS legacy v1.2.0 allocates v1.2.1 with matching ZIP identity'

$sourceMarkers = "<!-- upstream-source-tag: dsh-v0.1.2-alpha.1 -->`n<!-- upstream-source-sha: 2222222222222222222222222222222222222222 -->"
$body121 = "<!-- portable-version: 1.2.1 -->`n<!-- dsh-version: 0.1.2-alpha.1 -->`n$sourceMarkers"
$body122 = "<!-- portable-version: 1.2.2 -->`n<!-- dsh-version: 0.1.2-alpha.1 -->`n$sourceMarkers"
$release121 = New-TestRelease -Tag 'v1.2.1' -ZipVersion '1.2.1' -AssetPrefix 'DeepSeek-Harness' -Body $body121
$release122 = New-TestRelease -Tag 'v1.2.2' -ZipVersion '1.2.2' -Body $body122
$mapped = Resolve-DshPortableReleasePolicy `
  -Releases @($legacy, $release121, $release122) `
  -DshVersion '0.1.2-alpha.1' `
  -ExpectedSourceTag 'dsh-v0.1.2-alpha.1' `
  -ExpectedSourceSha '2222222222222222222222222222222222222222'
Assert-Equal $true $mapped.AlreadyPackaged 'any complete dsh marker must establish idempotence'
Assert-Equal 'v1.2.2' $mapped.ReleaseTag 'multiple patches for one dsh must select the highest portable version'
Assert-Equal $false $mapped.Prerelease 'stable portable tags must not inherit the dsh prerelease state'
Write-Output 'PASS multiple portable patches for one dsh select the highest complete Release'

$manual = Resolve-DshPortableReleasePolicy -Releases @($legacy, $release121) -DshVersion '0.1.2-alpha.1'
Assert-Equal $true $manual.AlreadyPackaged 'manual portable Release must use the shared source identity markers'
Write-Output 'PASS a manual portable Release uses the shared portable and source identity'

$missingSourceBody = "<!-- portable-version: 1.2.1 -->`n<!-- dsh-version: 0.1.2-alpha.1 -->"
$missingSource = New-TestRelease -Tag 'v1.2.1' -ZipVersion '1.2.1' -Body $missingSourceBody
Assert-Throws -Pattern '*incomplete source identity markers*' -Action {
  Resolve-DshPortableReleasePolicy `
    -Releases @($legacy, $missingSource) `
    -DshVersion '0.1.2-alpha.1' `
    -ExpectedSourceTag 'dsh-v0.1.2-alpha.1' `
    -ExpectedSourceSha '2222222222222222222222222222222222222222' | Out-Null
}
Write-Output 'PASS future portable Releases require exact upstream source markers'

$automatic = New-TestRelease -Tag 'v1.2.1' -ZipVersion '1.2.1' -Body $body121
Assert-Throws -Pattern '*records a different upstream source*' -Action {
  Resolve-DshPortableReleasePolicy `
    -Releases @($legacy, $automatic) `
    -DshVersion '0.1.2-alpha.1' `
    -ExpectedSourceTag 'dsh-v0.1.2-alpha.1' `
    -ExpectedSourceSha '3333333333333333333333333333333333333333' | Out-Null
}
Write-Output 'PASS automatic Release provenance rejects a moved official source tag'

$legacyDshBody = '<!-- dsh-version: 0.1.1-rc.2 -->'
$legacyDshRelease = New-TestRelease `
  -Tag 'dsh-v0.1.1-rc.2' `
  -ZipVersion '0.1.1-rc.2' `
  -AssetPrefix 'DeepSeek-Harness' `
  -Body $legacyDshBody `
  -Prerelease $true
$legacyDshMapping = Resolve-DshPortableReleasePolicy `
  -Releases @($legacy, $legacyDshRelease) `
  -DshVersion '0.1.1-rc.2' `
  -ExpectedSourceTag 'dsh-v0.1.1-rc.2' `
  -ExpectedSourceSha '4444444444444444444444444444444444444444'
Assert-Equal $true $legacyDshMapping.AlreadyPackaged 'the historical dsh-tag Release marker must remain idempotent'
Assert-Equal 'dsh-v0.1.1-rc.2' $legacyDshMapping.ReleaseTag 'legacy source-less dsh Release must remain readable'
Write-Output 'PASS the historical dsh-tag Release remains an idempotence record'

$draft = New-TestRelease -Tag 'v9.0.0' -ZipVersion '9.0.0' -Body "<!-- portable-version: 9.0.0 -->`n<!-- dsh-version: 0.1.2-alpha.1 -->" -Draft $true -Prerelease $true
$draftIgnored = Resolve-DshPortableReleasePolicy -Releases @($legacy, $draft) -DshVersion '0.1.2-alpha.1'
Assert-Equal 'v1.2.1' $draftIgnored.ReleaseTag 'isolated Drafts must not occupy the portable version stream'
Write-Output 'PASS Draft markers and assets do not occupy a public portable version'

$mismatch = New-TestRelease -Tag 'v1.3.0' -ZipVersion '1.2.9' -Body '<!-- portable-version: 1.3.0 -->'
Assert-Throws -Pattern '*inconsistent portable version metadata*' -Action {
  Resolve-DshPortableReleasePolicy -Releases @($legacy, $mismatch) -DshVersion '0.1.2-alpha.1' | Out-Null
}
Write-Output 'PASS future tag, ZIP, and marker disagreement fails closed'

$partial = New-TestRelease -Tag 'v1.3.0' -ZipVersion '1.3.0' -Body '<!-- portable-version: 1.3.0 -->'
$partial.assets = @($partial.assets[0])
Assert-Throws -Pattern '*incomplete asset set*' -Action {
  Resolve-DshPortableReleasePolicy -Releases @($legacy, $partial) -DshVersion '0.1.2-alpha.1' | Out-Null
}
Write-Output 'PASS incomplete future public Releases cannot become allocation floors'

$invalidDigestBody = "<!-- portable-version: 1.3.0 -->`n<!-- dsh-version: 0.1.2-alpha.1 -->`n$sourceMarkers"
$invalidDigest = New-TestRelease -Tag 'v1.3.0' -ZipVersion '1.3.0' -Body $invalidDigestBody
$invalidDigest.assets[0].digest = 'sha256:unknown'
Assert-Throws -Pattern '*incomplete asset set*' -Action {
  Resolve-DshPortableReleasePolicy -Releases @($legacy, $invalidDigest) -DshVersion '0.1.2-alpha.1' | Out-Null
}
Write-Output 'PASS future public Release assets require uploaded state, positive size, and SHA256 digest records'

$damagedLegacy = New-TestRelease -Tag 'v1.2.0' -ZipVersion '0.1.1-rc.2' -AssetPrefix 'DeepSeek-Harness'
$damagedLegacy.assets[0].state = 'new'
Assert-Throws -Pattern '*incomplete asset set*' -Action {
  Resolve-DshPortableReleasePolicy -Releases @($damagedLegacy) -DshVersion '0.1.2-alpha.1' | Out-Null
}
Write-Output 'PASS the historical version floor still requires complete asset records'

$wrongLegacy = New-TestRelease -Tag 'v1.2.0' -ZipVersion '0.1.0' -AssetPrefix 'DeepSeek-Harness'
Assert-Throws -Pattern '*unexpected ZIP version*' -Action {
  Resolve-DshPortableReleasePolicy -Releases @($wrongLegacy) -DshVersion '0.1.2-alpha.1' | Out-Null
}
Write-Output 'PASS historical compatibility accepts only the published legacy ZIP identity'

$duplicateMarkerBody = "$body121`n<!-- portable-version: 1.2.1 -->"
$duplicateMarker = New-TestRelease -Tag 'v1.2.1' -ZipVersion '1.2.1' -Body $duplicateMarkerBody
Assert-Throws -Pattern '*exactly one portable-version marker*' -Action {
  Resolve-DshPortableReleasePolicy -Releases @($duplicateMarker) -DshVersion '0.1.2' | Out-Null
}
Write-Output 'PASS future portable identity markers must be unique'

$previewBody = "<!-- portable-version: 1.3.0-rc.1 -->`n<!-- dsh-version: 0.1.1 -->`n<!-- upstream-source-tag: dsh-v0.1.1 -->`n<!-- upstream-source-sha: 5555555555555555555555555555555555555555 -->"
$previewFloor = New-TestRelease -Tag 'v1.3.0-rc.1' -ZipVersion '1.3.0-rc.1' -Body $previewBody -Prerelease $true
$previewNext = Resolve-DshPortableReleasePolicy -Releases @($previewFloor) -DshVersion '0.1.2'
Assert-Equal '1.3.1' $previewNext.PortableVersion 'allocation must always increment the patch number'
Write-Output 'PASS a prerelease floor still allocates the next patch version'

$alphaAllocation = Resolve-DshPortableReleasePolicy -Releases @($legacy) -DshVersion '0.1.2-alpha.1'
Assert-Equal $false $alphaAllocation.Prerelease 'a stable allocated portable version must not inherit upstream prerelease metadata'
Write-Output 'PASS portable prerelease metadata follows the portable version axis'

$automaticCurrent = Assert-DshAutomaticPortableAllocationCurrent `
  -Releases @($legacy) `
  -DshVersion '0.1.2-alpha.1' `
  -ExpectedPortableVersion '1.2.1' `
  -ExpectedReleaseTag 'v1.2.1' `
  -ExpectedPreviousPortableCommit '1111111111111111111111111111111111111111' `
  -ExpectedPreviousPortableTag 'v1.2.0' `
  -ExpectedSourceTag 'dsh-v0.1.2-alpha.1' `
  -ExpectedSourceSha '2222222222222222222222222222222222222222'
Assert-Equal 'v1.2.1' $automaticCurrent.ReleaseTag 'automatic allocation guard must preserve the expected version'
Assert-Throws -Pattern '*became public while its Draft was staged*' -Action {
  Assert-DshAutomaticPortableAllocationCurrent `
    -Releases @($legacy, $release121) `
    -DshVersion '0.1.2-alpha.1' `
    -ExpectedPortableVersion '1.2.1' `
    -ExpectedReleaseTag 'v1.2.1' `
    -ExpectedPreviousPortableCommit '1111111111111111111111111111111111111111' `
    -ExpectedPreviousPortableTag 'v1.2.0' `
    -ExpectedSourceTag 'dsh-v0.1.2-alpha.1' `
    -ExpectedSourceSha '2222222222222222222222222222222222222222' | Out-Null
}
$automaticAlreadyPublic = Assert-DshAutomaticPortableAllocationCurrent `
  -Releases @($legacy, $release121) `
  -DshVersion '0.1.2-alpha.1' `
  -ExpectedPortableVersion '1.2.1' `
  -ExpectedReleaseTag 'v1.2.1' `
  -ExpectedPreviousPortableCommit '1111111111111111111111111111111111111111' `
  -ExpectedPreviousPortableTag 'v1.2.0' `
  -ExpectedSourceTag 'dsh-v0.1.2-alpha.1' `
  -ExpectedSourceSha '2222222222222222222222222222222222222222' `
  -AllowExactAlreadyPublic
Assert-Equal $true $automaticAlreadyPublic.AlreadyPackaged 'pre-Draft automatic guard may accept the exact public Release read-only'
Write-Output 'PASS automatic allocation guard rejects a public Release appearing after Draft staging'

$manualCurrent = Assert-DshManualPortableAllocationCurrent `
  -Releases @($legacy) `
  -CurrentTag 'v1.2.1' `
  -CurrentVersion '1.2.1' `
  -ExpectedPreviousPortableCommit '1111111111111111111111111111111111111111' `
  -ExpectedPreviousPortableTag 'v1.2.0'
Assert-Equal $false $manualCurrent.AlreadyPublic 'manual allocation guard must preserve an unpublished next version'
Assert-Throws -Pattern '*became public while its Draft was staged*' -Action {
  Assert-DshManualPortableAllocationCurrent `
    -Releases @($legacy, $release121) `
    -CurrentTag 'v1.2.1' `
    -CurrentVersion '1.2.1' `
    -ExpectedPreviousPortableCommit '1111111111111111111111111111111111111111' `
    -ExpectedPreviousPortableTag 'v1.2.0' | Out-Null
}
$manualAlreadyPublic = Assert-DshManualPortableAllocationCurrent `
  -Releases @($legacy, $release121) `
  -CurrentTag 'v1.2.1' `
  -CurrentVersion '1.2.1' `
  -ExpectedPreviousPortableCommit '1111111111111111111111111111111111111111' `
  -ExpectedPreviousPortableTag 'v1.2.0' `
  -AllowExactAlreadyPublic
Assert-Equal $true $manualAlreadyPublic.AlreadyPublic 'pre-Draft manual guard may accept the exact public Release read-only'
Write-Output 'PASS manual allocation guard rejects a public Release appearing after Draft staging'

Write-Output 'PASS all portable Release policy tests'
