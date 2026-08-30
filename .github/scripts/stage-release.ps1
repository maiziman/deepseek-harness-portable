# Create an isolated Draft Release id and upload a verified package pair. The
# temporary Draft tag is changed to the requested tag only during finalization,
# so an interrupted run cannot require deleting or replacing Release assets.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repository,
  [Parameter(Mandatory)][string]$Tag,
  [Parameter(Mandatory)][Alias('ZipName')][string]$PackageName,
  [ValidateSet('true', 'false')][string]$Prerelease = 'false',
  [ValidateSet('legacy', 'true', 'false')][string]$MakeLatest = 'legacy',
  [string]$AssetsDir = 'release-assets',
  [string]$ReleaseName = '',
  [string]$Body = '',
  [string]$TargetCommitish = '',
  [string]$PreviousTagName = '',
  [switch]$GenerateReleaseNotes,
  [switch]$AppendGeneratedReleaseNotes,
  [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'release-common.ps1')

Assert-DshReleaseRepository -Repository $Repository
Assert-DshReleaseTag -Tag $Tag
foreach ($value in @($ReleaseName, $TargetCommitish, $PreviousTagName)) {
  if ($value -match '[\r\n]') { throw 'release metadata must not contain a newline' }
}
if ($AppendGeneratedReleaseNotes -and -not $GenerateReleaseNotes) {
  throw 'AppendGeneratedReleaseNotes requires GenerateReleaseNotes'
}
if ($AppendGeneratedReleaseNotes -and -not $PreviousTagName) {
  throw 'AppendGeneratedReleaseNotes requires an explicit PreviousTagName'
}
if ($AppendGeneratedReleaseNotes -and -not $Body) {
  throw 'AppendGeneratedReleaseNotes requires a fixed Body prefix'
}

$assetContext = Get-DshValidatedReleaseAssets -PackageName $PackageName -AssetsDir $AssetsDir
Write-Output "local release assets verified: $PackageName"
if ($ValidateOnly) { return }
if ($TargetCommitish -notmatch '^[0-9a-fA-F]{40}$') {
  throw 'TargetCommitish must be the exact 40-character build commit SHA'
}

$headers = New-DshGitHubHeaders
$targetRelease = Get-DshUniqueReleaseForTag -Repository $Repository -Tag $Tag -Headers $headers

if ($null -ne $targetRelease -and -not (Test-DshReleaseIsDraft -Release $targetRelease)) {
  $releaseId = [string]$targetRelease.id
  $targetRelease = Get-DshReleaseById -Repository $Repository -ReleaseId $releaseId -Headers $headers
  Assert-DshReleaseIdentity -Release $targetRelease -Tag $Tag -ReleaseId $releaseId
  if (Test-DshReleaseIsDraft -Release $targetRelease) {
    throw "Release $releaseId changed from public to Draft during inspection"
  }
  Assert-DshTagCommitSha `
    -Repository $Repository `
    -Tag $Tag `
    -ExpectedSha $TargetCommitish `
    -Headers $headers
  Assert-DshCompletePublicRelease `
    -Release $targetRelease `
    -Tag $Tag `
    -AssetContext $assetContext `
    -Repository $Repository `
    -Headers $headers `
    -ExpectedCommit $TargetCommitish `
    -Prerelease $Prerelease `
    -MakeLatest $MakeLatest
  if ($AppendGeneratedReleaseNotes) {
    $requiredPrefix = "$Body`n`n"
    if (-not ([string]$targetRelease.body).StartsWith($requiredPrefix, [StringComparison]::Ordinal)) {
      throw "published Release $Tag has an unexpected identity prefix"
    }
  } elseif ($Body) {
    Assert-DshReleaseBodySha256 -Release $targetRelease -ExpectedSha256 (Get-DshTextSha256 -Text $Body)
  }
  if ($ReleaseName -and [string]$targetRelease.name -cne $ReleaseName) {
    throw "published Release $Tag has an unexpected name"
  }
  Set-DshGitHubOutput -Name 'release_id' -Value ([string]$targetRelease.id)
  Set-DshGitHubOutput -Name 'body_sha256' -Value (Get-DshTextSha256 -Text ([string]$targetRelease.body))
  Set-DshGitHubOutput -Name 'should_publish' -Value 'false'
  Set-DshGitHubOutput -Name 'skipped' -Value 'true'
  Write-Output "complete public Release already exists; staging skipped: $($targetRelease.html_url)"
  return
}

if ($null -ne $targetRelease) {
  throw "tag $Tag already has Draft Release $($targetRelease.id); remove that legacy Draft manually before retrying"
}
Assert-DshTagCommitSha `
  -Repository $Repository `
  -Tag $Tag `
  -ExpectedSha $TargetCommitish `
  -Headers $headers `
  -AllowMissing

$resolvedReleaseName = $ReleaseName
$resolvedBody = $Body
if ($GenerateReleaseNotes) {
  $notesPayload = [ordered]@{ tag_name = $Tag }
  if ($TargetCommitish) { $notesPayload.target_commitish = $TargetCommitish }
  if ($PreviousTagName) { $notesPayload.previous_tag_name = $PreviousTagName }
  $generatedNotes = Invoke-RestMethod `
    -Method Post `
    -Headers $headers `
    -Uri "https://api.github.com/repos/$Repository/releases/generate-notes" `
    -ContentType 'application/json' `
    -Body ($notesPayload | ConvertTo-Json)
  if (-not $resolvedReleaseName) { $resolvedReleaseName = [string]$generatedNotes.name }
  if ($AppendGeneratedReleaseNotes) {
    $generatedBody = [string]$generatedNotes.body
    if ($generatedBody) { $resolvedBody = "$resolvedBody`n`n$generatedBody" }
  } elseif (-not $resolvedBody) {
    $resolvedBody = [string]$generatedNotes.body
  }
}
$resolvedBodySha256 = Get-DshTextSha256 -Text $resolvedBody

if ($env:GITHUB_RUN_ID -notmatch '^[0-9]+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^[0-9]+$') {
  throw 'GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT are required to create an isolated Draft'
}
$draftSuffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$draftTag = "$Tag-draft-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)-$draftSuffix"
Assert-DshReleaseTag -Tag $draftTag

$createPayload = [ordered]@{
  tag_name = $draftTag
  draft = $true
  prerelease = $Prerelease -eq 'true'
  make_latest = $MakeLatest
  generate_release_notes = $false
}
if ($TargetCommitish) { $createPayload.target_commitish = $TargetCommitish }
if ($resolvedReleaseName) { $createPayload.name = $resolvedReleaseName }
if ($resolvedBody) { $createPayload.body = $resolvedBody }

try {
  $release = Invoke-RestMethod `
    -Method Post `
    -Headers $headers `
    -Uri "https://api.github.com/repos/$Repository/releases" `
    -ContentType 'application/json' `
    -Body ($createPayload | ConvertTo-Json)
} catch {
  throw "failed to create isolated Draft Release for ${Tag}: $($_.Exception.Message)"
}
Assert-DshReleaseIdentity -Release $release -Tag $draftTag
if (-not (Test-DshReleaseIsDraft -Release $release)) {
  throw "GitHub created non-Draft Release $($release.id); refusing to upload assets"
}
Write-Output "created isolated Draft Release $draftTag with exact id $($release.id)"

if ([bool]$release.prerelease -ne ($Prerelease -eq 'true')) {
  throw "Draft Release $Tag has the wrong prerelease state"
}
if ($resolvedReleaseName -and [string]$release.name -cne $resolvedReleaseName) {
  throw "Draft Release $Tag has an unexpected name"
}
if ($resolvedBody -and [string]$release.body -cne $resolvedBody) {
  throw "Draft Release $Tag has an unexpected body"
}
Assert-DshReleaseBodySha256 -Release $release -ExpectedSha256 $resolvedBodySha256
if ($TargetCommitish -and [string]$release.target_commitish -cne $TargetCommitish) {
  throw "Draft Release $Tag has an unexpected target commitish"
}

$releaseId = [string]$release.id
if ($releaseId -notmatch '^[0-9]+$') { throw "GitHub returned an invalid Release id for $Tag" }

$release = Get-DshReleaseById -Repository $Repository -ReleaseId $releaseId -Headers $headers
Assert-DshReleaseIdentity -Release $release -Tag $draftTag -ReleaseId $releaseId
if (-not (Test-DshReleaseIsDraft -Release $release)) {
  throw "Release $releaseId became public before asset staging"
}
$assetState = Assert-DshRemoteAssets -Release $release -AssetContext $assetContext -AllowMissing

foreach ($assetName in $assetState.MissingNames) {
  $release = Get-DshReleaseById -Repository $Repository -ReleaseId $releaseId -Headers $headers
  Assert-DshReleaseIdentity -Release $release -Tag $draftTag -ReleaseId $releaseId
  if (-not (Test-DshReleaseIsDraft -Release $release)) {
    throw "Release $releaseId became public during asset staging"
  }
  $currentState = Assert-DshRemoteAssets -Release $release -AssetContext $assetContext -AllowMissing
  if ($assetName -notin $currentState.MissingNames) { continue }

  $assetSpec = $assetContext.ExpectedAssets[$assetName]
  $escapedName = [uri]::EscapeDataString($assetName)
  Invoke-RestMethod `
    -Method Post `
    -Headers $headers `
    -Uri "https://uploads.github.com/repos/$Repository/releases/$releaseId/assets?name=$escapedName" `
    -ContentType 'application/octet-stream' `
    -InFile $assetSpec.Path | Out-Null

  $release = Get-DshReleaseById -Repository $Repository -ReleaseId $releaseId -Headers $headers
  Assert-DshReleaseIdentity -Release $release -Tag $draftTag -ReleaseId $releaseId
  if (-not (Test-DshReleaseIsDraft -Release $release)) {
    throw "Release $releaseId became public while $assetName was uploading"
  }
  $postUploadState = Assert-DshRemoteAssets -Release $release -AssetContext $assetContext -AllowMissing
  if ($assetName -in $postUploadState.MissingNames) {
    throw "GitHub did not retain uploaded Draft asset: $assetName"
  }
  Write-Output "uploaded verified Draft asset: $assetName"
}

$release = Get-DshReleaseById -Repository $Repository -ReleaseId $releaseId -Headers $headers
Assert-DshReleaseIdentity -Release $release -Tag $draftTag -ReleaseId $releaseId
if (-not (Test-DshReleaseIsDraft -Release $release)) {
  throw "Release $releaseId became public before final Draft validation"
}
Assert-DshRemoteAssets -Release $release -AssetContext $assetContext | Out-Null
Assert-DshReleaseBodySha256 -Release $release -ExpectedSha256 $resolvedBodySha256

Set-DshGitHubOutput -Name 'release_id' -Value $releaseId
Set-DshGitHubOutput -Name 'body_sha256' -Value $resolvedBodySha256
Set-DshGitHubOutput -Name 'draft_tag' -Value $draftTag
Set-DshGitHubOutput -Name 'should_publish' -Value 'true'
Set-DshGitHubOutput -Name 'skipped' -Value 'false'
Write-Output "Draft Release is complete and ready to publish: $($release.html_url)"
