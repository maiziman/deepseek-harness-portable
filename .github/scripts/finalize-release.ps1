# Validate local and remote Release assets before any public state change.
# Preflight blocks writes to an existing public Release; finalization addresses
# the exact Draft id returned by the staging action and publishes only after the
# remote SHA256 digests match the local files.
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$Repository,
  [Parameter(Mandatory)]
  [string]$Tag,
  [Parameter(Mandatory)]
  [string]$ZipName,
  [ValidateSet('true', 'false')]
  [string]$Prerelease = 'false',
  [string]$AssetsDir = 'release-assets',
  [string]$ReleaseId = '',
  [switch]$Preflight,
  [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "invalid GitHub repository: $Repository" }
if (-not $Tag -or $Tag -match '[\r\n]') { throw 'release tag is empty or invalid' }
if ([IO.Path]::GetFileName($ZipName) -cne $ZipName) { throw "ZIP name must not contain a path: $ZipName" }
if ($Preflight -and $ReleaseId) { throw 'ReleaseId is not accepted during preflight' }
if (-not $Preflight -and -not $ValidateOnly -and $ReleaseId -notmatch '^[0-9]+$') { throw 'a numeric ReleaseId is required for finalization' }

$zipPath = Join-Path $AssetsDir $ZipName
$sumsPath = Join-Path $AssetsDir 'SHA256SUMS.txt'
if (-not (Test-Path $zipPath -PathType Leaf)) { throw "release ZIP missing: $zipPath" }
if (-not (Test-Path $sumsPath -PathType Leaf)) { throw "release checksum file missing: $sumsPath" }

$checksumLines = @(Get-Content $sumsPath | Where-Object { $_.Trim() })
if ($checksumLines.Count -ne 1) { throw 'SHA256SUMS.txt must contain exactly one non-empty line' }
$checksumPattern = '^(?<sha>[0-9a-fA-F]{64})  ' + [regex]::Escape($ZipName) + '$'
if ($checksumLines[0] -cnotmatch $checksumPattern) { throw "SHA256SUMS.txt does not name $ZipName" }
$expectedZipHash = $Matches.sha.ToLowerInvariant()
$actualZipHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualZipHash -ne $expectedZipHash) { throw "release ZIP SHA256 mismatch: $actualZipHash" }

$expectedAssets = [ordered]@{}
$expectedAssets[$ZipName] = @{
  Length = (Get-Item $zipPath).Length
  Digest = "sha256:$actualZipHash"
}
$sumsHash = (Get-FileHash $sumsPath -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedAssets['SHA256SUMS.txt'] = @{
  Length = (Get-Item $sumsPath).Length
  Digest = "sha256:$sumsHash"
}
Write-Output "local release assets verified: $ZipName"

if ($ValidateOnly) { return }
if (-not $env:GH_TOKEN) { throw 'GH_TOKEN is required to inspect or publish a Release' }

$headers = @{
  Accept = 'application/vnd.github+json'
  Authorization = "Bearer $env:GH_TOKEN"
  'X-GitHub-Api-Version' = '2022-11-28'
}

function Assert-RemoteAssets([object]$Release) {
  if (@($Release.assets).Count -ne $expectedAssets.Count) {
    throw "Release $Tag must contain exactly $($expectedAssets.Count) assets"
  }
  foreach ($entry in $expectedAssets.GetEnumerator()) {
    $assetMatches = @($Release.assets | Where-Object { $_.name -ceq $entry.Key })
    if ($assetMatches.Count -ne 1) { throw "Release $Tag must contain exactly one $($entry.Key) asset" }
    $asset = $assetMatches[0]
    if ($asset.state -cne 'uploaded') { throw "Release asset is not fully uploaded: $($entry.Key)" }
    if ([int64]$asset.size -ne [int64]$entry.Value.Length) { throw "Release asset size mismatch: $($entry.Key)" }
    if (([string]$asset.digest).ToLowerInvariant() -ne [string]$entry.Value.Digest) { throw "Release asset SHA256 mismatch: $($entry.Key)" }
  }
}

function Assert-PublicReleaseComplete([object]$Release) {
  if (@($Release.assets).Count -ne 2) { throw "public Release $Tag must contain exactly two assets" }
  $zipMatches = @($Release.assets | Where-Object { $_.name -ceq $ZipName })
  $sumsMatches = @($Release.assets | Where-Object { $_.name -ceq 'SHA256SUMS.txt' })
  if ($zipMatches.Count -ne 1 -or $sumsMatches.Count -ne 1) { throw "public Release $Tag is missing the ZIP/checksum pair" }
  $zipAsset = $zipMatches[0]
  $sumsAsset = $sumsMatches[0]
  foreach ($asset in @($zipAsset, $sumsAsset)) {
    if ($asset.state -cne 'uploaded' -or [int64]$asset.size -le 0) { throw "public Release asset is incomplete: $($asset.name)" }
    if ([string]$asset.digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw "public Release asset has no SHA256 digest: $($asset.name)" }
  }

  $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("dsh-release-check-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tempDir | Out-Null
  $remoteSumsPath = Join-Path $tempDir 'SHA256SUMS.txt'
  try {
    $downloadHeaders = $headers.Clone()
    $downloadHeaders.Accept = 'application/octet-stream'
    Invoke-WebRequest -Headers $downloadHeaders -Uri "https://api.github.com/repos/$Repository/releases/assets/$($sumsAsset.id)" -OutFile $remoteSumsPath
    if ((Get-Item $remoteSumsPath).Length -ne [int64]$sumsAsset.size) { throw 'published SHA256SUMS.txt size does not match its asset record' }
    $remoteSumsDigest = 'sha256:' + (Get-FileHash $remoteSumsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($remoteSumsDigest -ne ([string]$sumsAsset.digest).ToLowerInvariant()) { throw 'published SHA256SUMS.txt digest does not match its asset record' }
    $remoteLines = @(Get-Content $remoteSumsPath | Where-Object { $_.Trim() })
    $remotePattern = '^' + [regex]::Escape(([string]$zipAsset.digest).Substring(7)) + '  ' + [regex]::Escape($ZipName) + '$'
    if ($remoteLines.Count -ne 1 -or $remoteLines[0] -cnotmatch $remotePattern) { throw 'published SHA256SUMS.txt does not verify the published ZIP' }
  } finally {
    $resolvedTempDir = (Resolve-Path $tempDir).Path
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTempDir.StartsWith($resolvedTempRoot) -or (Split-Path $resolvedTempDir -Leaf) -notmatch '^dsh-release-check-[0-9a-f]{32}$') {
      throw "refusing to remove unexpected temporary path: $resolvedTempDir"
    }
    Remove-Item -LiteralPath $resolvedTempDir -Recurse -Force
  }
}

if ($Preflight) {
  $tagReleases = @()
  for ($page = 1; ; $page++) {
    $pageReleases = @(Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases?per_page=100&page=$page")
    $tagReleases += @($pageReleases | Where-Object { $_.tag_name -ceq $Tag })
    if ($pageReleases.Count -lt 100) { break }
  }
  if ($tagReleases.Count -gt 1) { throw "multiple Releases use tag $Tag; refusing to choose one" }
  if ($tagReleases.Count -eq 1 -and -not $tagReleases[0].draft) {
    Assert-PublicReleaseComplete $tagReleases[0]
    "should_stage=false" >> $env:GITHUB_OUTPUT
    Write-Output "complete public Release already exists: $($tagReleases[0].html_url)"
  } else {
    "should_stage=true" >> $env:GITHUB_OUTPUT
    if ($tagReleases.Count -eq 1) { Write-Output "existing Draft Release is safe to restage: $Tag" }
    else { Write-Output "no existing Release uses tag $Tag" }
  }
  return
}

$release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases/$ReleaseId"
if ([string]$release.tag_name -cne $Tag) { throw "Release $ReleaseId uses unexpected tag $($release.tag_name)" }
if (-not $release.draft) { throw "refusing to finalize non-Draft Release $Tag" }
Assert-RemoteAssets $release

$payload = @{
  draft = $false
  prerelease = $Prerelease -eq 'true'
} | ConvertTo-Json
$published = Invoke-RestMethod -Method Patch -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases/$ReleaseId" -ContentType 'application/json' -Body $payload
if ($published.draft) { throw "GitHub left Release $Tag in Draft state" }
if ([bool]$published.prerelease -ne ($Prerelease -eq 'true')) { throw "GitHub returned the wrong prerelease state for $Tag" }
Assert-RemoteAssets $published
Write-Output "published complete Release: $($published.html_url)"
