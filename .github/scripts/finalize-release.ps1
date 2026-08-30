# Validate an exact isolated Draft Release id, then assign the requested tag and
# publish it in one GitHub API mutation.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repository,
  [Parameter(Mandatory)][string]$Tag,
  [Parameter(Mandatory)][Alias('ZipName')][string]$PackageName,
  [ValidateSet('true', 'false')][string]$Prerelease = 'false',
  [ValidateSet('legacy', 'true', 'false')][string]$MakeLatest = 'legacy',
  [string]$AssetsDir = 'release-assets',
  [string]$ReleaseId = '',
  [string]$DraftTag = '',
  [string]$ExpectedCommit = '',
  [string]$ExpectedBodySha256 = '',
  [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'release-common.ps1')

Assert-DshReleaseRepository -Repository $Repository
Assert-DshReleaseTag -Tag $Tag
if (-not $ValidateOnly -and $ReleaseId -notmatch '^[0-9]+$') {
  throw 'a numeric ReleaseId is required for finalization'
}
if (-not $ValidateOnly) {
  Assert-DshReleaseTag -Tag $DraftTag
  if ($DraftTag -ceq $Tag) { throw 'DraftTag must be isolated from the public Release tag' }
  if ($ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'ExpectedCommit must be the exact 40-character build commit SHA'
  }
  if ($ExpectedBodySha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'ExpectedBodySha256 must be a lowercase SHA256 digest from the staging step'
  }
}

$assetContext = Get-DshValidatedReleaseAssets -PackageName $PackageName -AssetsDir $AssetsDir
Write-Output "local release assets verified: $PackageName"
if ($ValidateOnly) { return }

$headers = New-DshGitHubHeaders

$release = Get-DshReleaseById -Repository $Repository -ReleaseId $ReleaseId -Headers $headers
Assert-DshReleaseBodySha256 -Release $release -ExpectedSha256 $ExpectedBodySha256

if (-not (Test-DshReleaseIsDraft -Release $release)) {
  Assert-DshReleaseIdentity -Release $release -Tag $Tag -ReleaseId $ReleaseId
  Assert-DshTagCommitSha `
    -Repository $Repository `
    -Tag $Tag `
    -ExpectedSha $ExpectedCommit `
    -Headers $headers
  Assert-DshCompletePublicRelease `
    -Release $release `
    -Tag $Tag `
    -AssetContext $assetContext `
    -Repository $Repository `
    -Headers $headers `
    -ExpectedCommit $ExpectedCommit `
    -Prerelease $Prerelease `
    -MakeLatest $MakeLatest
  Set-DshGitHubOutput -Name 'published' -Value 'false'
  Set-DshGitHubOutput -Name 'skipped' -Value 'true'
  Set-DshGitHubOutput -Name 'release_id' -Value $ReleaseId
  Write-Output "complete public Release already exists; publication skipped: $($release.html_url)"
  return
}
Assert-DshReleaseIdentity -Release $release -Tag $DraftTag -ReleaseId $ReleaseId
if ([string]$release.target_commitish -cne $ExpectedCommit) {
  throw "isolated Draft $ReleaseId target commit changed from $ExpectedCommit to $($release.target_commitish)"
}
$targetRelease = Get-DshUniqueReleaseForTag -Repository $Repository -Tag $Tag -Headers $headers
if ($null -ne $targetRelease) {
  throw "Release state changed for tag $Tag; refusing to publish isolated Draft id $ReleaseId"
}
Assert-DshTagCommitSha `
  -Repository $Repository `
  -Tag $Tag `
  -ExpectedSha $ExpectedCommit `
  -Headers $headers `
  -AllowMissing
Assert-DshRemoteAssets -Release $release -AssetContext $assetContext | Out-Null

# Re-read the exact id and target tag immediately before the only public-state
# mutation. GitHub applies the final tag assignment and publication together.
$release = Get-DshReleaseById -Repository $Repository -ReleaseId $ReleaseId -Headers $headers
Assert-DshReleaseBodySha256 -Release $release -ExpectedSha256 $ExpectedBodySha256
Assert-DshReleaseIdentity -Release $release -Tag $DraftTag -ReleaseId $ReleaseId
if (-not (Test-DshReleaseIsDraft -Release $release)) {
  throw "isolated Release $ReleaseId became public before finalization"
}
if ([string]$release.target_commitish -cne $ExpectedCommit) {
  throw "isolated Draft $ReleaseId target commit changed immediately before publication"
}
$targetRelease = Get-DshUniqueReleaseForTag -Repository $Repository -Tag $Tag -Headers $headers
if ($null -ne $targetRelease) {
  throw "Release state changed for tag $Tag immediately before publication"
}
Assert-DshTagCommitSha `
  -Repository $Repository `
  -Tag $Tag `
  -ExpectedSha $ExpectedCommit `
  -Headers $headers `
  -AllowMissing
Assert-DshRemoteAssets -Release $release -AssetContext $assetContext | Out-Null

$payload = @{
  tag_name = $Tag
  target_commitish = $ExpectedCommit
  draft = $false
  prerelease = $Prerelease -eq 'true'
  make_latest = $MakeLatest
} | ConvertTo-Json
$published = Invoke-RestMethod `
  -Method Patch `
  -Headers $headers `
  -Uri "https://api.github.com/repos/$Repository/releases/$ReleaseId" `
  -ContentType 'application/json' `
  -Body $payload

Assert-DshReleaseIdentity -Release $published -Tag $Tag -ReleaseId $ReleaseId
Assert-DshReleaseBodySha256 -Release $published -ExpectedSha256 $ExpectedBodySha256
if (Test-DshReleaseIsDraft -Release $published) {
  throw "GitHub left Release $Tag in Draft state"
}
Assert-DshTagCommitSha `
  -Repository $Repository `
  -Tag $Tag `
  -ExpectedSha $ExpectedCommit `
  -Headers $headers
Assert-DshCompletePublicRelease `
  -Release $published `
  -Tag $Tag `
  -AssetContext $assetContext `
  -Repository $Repository `
  -Headers $headers `
  -ExpectedCommit $ExpectedCommit `
  -Prerelease $Prerelease `
  -MakeLatest $MakeLatest `
  -MatchLocal

Set-DshGitHubOutput -Name 'published' -Value 'true'
Set-DshGitHubOutput -Name 'skipped' -Value 'false'
Set-DshGitHubOutput -Name 'release_id' -Value $ReleaseId
Write-Output "published complete Release: $($published.html_url)"
