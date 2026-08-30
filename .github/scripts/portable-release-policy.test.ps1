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
    [string]$Body = '',
    [bool]$Draft = $false,
    [bool]$Prerelease = $false,
    [string]$Commit = '1111111111111111111111111111111111111111'
  )
  return [pscustomobject]@{
    assets = @(
      (New-TestAsset -Name "DeepSeek-Harness-win64-v$ZipVersion.zip")
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

$legacy = New-TestRelease -Tag 'v1.2.0' -ZipVersion '0.1.1-rc.2'
$allocation = Resolve-DshPortableReleasePolicy -Releases @($legacy) -DshVersion '0.1.2-alpha.1'
Assert-Equal $false $allocation.AlreadyPackaged 'legacy Release must remain only a version floor'
Assert-Equal '1.2.1' $allocation.PortableVersion 'legacy v1.2.0 must allocate the next portable patch'
Assert-Equal 'v1.2.1' $allocation.ReleaseTag 'automatic Releases must join the v* family'
Assert-Equal 'DeepSeek-Harness-win64-v1.2.1.zip' $allocation.AssetName 'ZIP must match the portable tag'
Write-Output 'PASS legacy v1.2.0 allocates v1.2.1 with matching ZIP identity'

$body121 = "<!-- portable-version: 1.2.1 -->`n<!-- dsh-version: 0.1.2-alpha.1 -->"
$body122 = "<!-- portable-version: 1.2.2 -->`n<!-- dsh-version: 0.1.2-alpha.1 -->"
$release121 = New-TestRelease -Tag 'v1.2.1' -ZipVersion '1.2.1' -Body $body121 -Prerelease $true
$release122 = New-TestRelease -Tag 'v1.2.2' -ZipVersion '1.2.2' -Body $body122 -Prerelease $true
$mapped = Resolve-DshPortableReleasePolicy -Releases @($legacy, $release121, $release122) -DshVersion '0.1.2-alpha.1'
Assert-Equal $true $mapped.AlreadyPackaged 'any complete dsh marker must establish idempotence'
Assert-Equal 'v1.2.2' $mapped.ReleaseTag 'multiple patches for one dsh must select the highest portable version'
Write-Output 'PASS multiple portable patches for one dsh select the highest complete Release'

$manual = Resolve-DshPortableReleasePolicy -Releases @($legacy, $release121) -DshVersion '0.1.2-alpha.1'
Assert-Equal $true $manual.AlreadyPackaged 'manual portable body needs no upstream source markers'
Write-Output 'PASS a manual portable Release uses the shared portable/dsh marker identity'

$automaticBody = "$body121`n<!-- upstream-source-tag: dsh-v0.1.2-alpha.1 -->`n<!-- upstream-source-sha: 2222222222222222222222222222222222222222 -->"
$automatic = New-TestRelease -Tag 'v1.2.1' -ZipVersion '1.2.1' -Body $automaticBody -Prerelease $true
Assert-Throws -Pattern '*records a different upstream source*' -Action {
  Resolve-DshPortableReleasePolicy `
    -Releases @($legacy, $automatic) `
    -DshVersion '0.1.2-alpha.1' `
    -ExpectedSourceTag 'dsh-v0.1.2-alpha.1' `
    -ExpectedSourceSha '3333333333333333333333333333333333333333' | Out-Null
}
Write-Output 'PASS automatic Release provenance rejects a moved official source tag'

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

$previewFloor = New-TestRelease -Tag 'v1.3.0-rc.1' -ZipVersion '1.3.0-rc.1' -Body '<!-- portable-version: 1.3.0-rc.1 -->' -Prerelease $true
$previewNext = Resolve-DshPortableReleasePolicy -Releases @($previewFloor) -DshVersion '0.1.2'
Assert-Equal '1.3.1' $previewNext.PortableVersion 'allocation must always increment the patch number'
Write-Output 'PASS a prerelease floor still allocates the next patch version'

Write-Output 'PASS all portable Release policy tests'
