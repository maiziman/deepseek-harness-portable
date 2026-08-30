Set-StrictMode -Version Latest

function Get-DshTextSha256 {
  param([AllowEmptyString()][Parameter(Mandatory)][string]$Text)

  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return -join ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
  } finally {
    $hasher.Dispose()
  }
}

function Assert-DshReleaseBodySha256 {
  param(
    [Parameter(Mandatory)][object]$Release,
    [Parameter(Mandatory)][string]$ExpectedSha256
  )

  if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'expected Release body SHA256 is invalid' }
  $actual = Get-DshTextSha256 -Text ([string]$Release.body)
  if ($actual -cne $ExpectedSha256) {
    throw "Release $($Release.id) body changed: expected $ExpectedSha256, found $actual"
  }
}

function Assert-DshReleaseNameSha256 {
  param(
    [Parameter(Mandatory)][object]$Release,
    [Parameter(Mandatory)][string]$ExpectedSha256
  )

  if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'expected Release name SHA256 is invalid' }
  $actual = Get-DshTextSha256 -Text ([string]$Release.name)
  if ($actual -cne $ExpectedSha256) {
    throw "Release $($Release.id) name changed: expected $ExpectedSha256, found $actual"
  }
}

function Assert-DshReleaseRepository {
  param([Parameter(Mandatory)][string]$Repository)

  if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "invalid GitHub repository: $Repository"
  }
}

function Assert-DshReleaseTag {
  param([Parameter(Mandatory)][string]$Tag)

  if (-not $Tag -or $Tag -match '[\r\n]') {
    throw 'release tag is empty or invalid'
  }
}

function Get-DshValidatedReleaseAssets {
  param(
    [Parameter(Mandatory)][string]$PackageName,
    [Parameter(Mandatory)][string]$AssetsDir
  )

  if ([IO.Path]::GetFileName($PackageName) -cne $PackageName) {
    throw "package name must not contain a path: $PackageName"
  }
  if ($PackageName -cnotmatch '\.(?:zip|tgz)$') {
    throw "release package must be a .zip or .tgz file: $PackageName"
  }

  $packagePath = Join-Path $AssetsDir $PackageName
  $sumsPath = Join-Path $AssetsDir 'SHA256SUMS.txt'
  if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    throw "release package missing: $packagePath"
  }
  if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) {
    throw "release checksum file missing: $sumsPath"
  }

  $package = Get-Item -LiteralPath $packagePath
  $sums = Get-Item -LiteralPath $sumsPath
  if ([int64]$package.Length -le 0) { throw "release package is empty: $packagePath" }
  if ([int64]$sums.Length -le 0) { throw "release checksum file is empty: $sumsPath" }

  $checksumLines = @(Get-Content -LiteralPath $sumsPath | Where-Object { $_.Trim() })
  if ($checksumLines.Count -ne 1) {
    throw 'SHA256SUMS.txt must contain exactly one non-empty line'
  }
  $checksumPattern = '^(?<sha>[0-9a-fA-F]{64})  ' + [regex]::Escape($PackageName) + '$'
  if ($checksumLines[0] -cnotmatch $checksumPattern) {
    throw "SHA256SUMS.txt does not name $PackageName"
  }

  $expectedPackageHash = $Matches.sha.ToLowerInvariant()
  $actualPackageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualPackageHash -ne $expectedPackageHash) {
    throw "release package SHA256 mismatch: $actualPackageHash"
  }

  $expectedAssets = [ordered]@{}
  $expectedAssets[$PackageName] = [pscustomobject]@{
    Path = $package.FullName
    Length = [int64]$package.Length
    Digest = "sha256:$actualPackageHash"
  }
  $sumsHash = (Get-FileHash -LiteralPath $sumsPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $expectedAssets['SHA256SUMS.txt'] = [pscustomobject]@{
    Path = $sums.FullName
    Length = [int64]$sums.Length
    Digest = "sha256:$sumsHash"
  }

  return [pscustomobject]@{
    PackageName = $PackageName
    ExpectedAssets = $expectedAssets
  }
}

function New-DshGitHubHeaders {
  if (-not $env:GH_TOKEN) {
    throw 'GH_TOKEN is required to inspect or publish a Release'
  }

  return @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $env:GH_TOKEN"
    'User-Agent' = 'deepseek-harness-portable-release-script'
    'X-GitHub-Api-Version' = '2022-11-28'
  }
}

function Get-DshReleaseById {
  param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$ReleaseId,
    [Parameter(Mandatory)][hashtable]$Headers
  )

  return Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/repos/$Repository/releases/$ReleaseId"
}

function Get-DshPublishedReleaseByTag {
  param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][hashtable]$Headers
  )

  $escapedTag = [uri]::EscapeDataString($Tag)
  try {
    return Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/repos/$Repository/releases/tags/$escapedTag"
  } catch {
    $statusCode = if ($null -ne $_.Exception.Response) { $_.Exception.Response.StatusCode } else { $null }
    if ($null -ne $statusCode -and [int]$statusCode -eq 404) { return $null }
    throw
  }
}

function Get-DshLatestRelease {
  param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][hashtable]$Headers
  )

  try {
    return Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/repos/$Repository/releases/latest"
  } catch {
    $statusCode = if ($null -ne $_.Exception.Response) { $_.Exception.Response.StatusCode } else { $null }
    if ($null -ne $statusCode -and [int]$statusCode -eq 404) { return $null }
    throw
  }
}

function Get-DshTagCommitSha {
  param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][hashtable]$Headers
  )

  $escapedTag = [uri]::EscapeDataString($Tag)
  try {
    $commit = Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/repos/$Repository/commits/$escapedTag"
  } catch {
    $statusCode = if ($null -ne $_.Exception.Response) { $_.Exception.Response.StatusCode } else { $null }
    $errorDetail = if ($null -ne $_.ErrorDetails) { [string]$_.ErrorDetails.Message } else { '' }
    $errorText = @([string]$_.Exception.Message, $errorDetail) -join "`n"
    $missingCommitMessage = "No commit found for SHA: $Tag"
    # Unlike the ref and Release endpoints, commits/{ref} reports a missing
    # ref as this exact 422 response rather than 404.
    if ($null -ne $statusCode -and (
        [int]$statusCode -eq 404 -or
        ([int]$statusCode -eq 422 -and $errorText.Contains($missingCommitMessage, [StringComparison]::Ordinal))
      )) { return $null }
    throw
  }
  $sha = ([string]$commit.sha).ToLowerInvariant()
  if ($sha -notmatch '^[0-9a-f]{40}$') { throw "GitHub returned an invalid commit SHA for tag $Tag" }
  return $sha
}

function Assert-DshTagCommitSha {
  param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$ExpectedSha,
    [Parameter(Mandatory)][hashtable]$Headers,
    [switch]$AllowMissing
  )

  $expected = $ExpectedSha.ToLowerInvariant()
  if ($expected -notmatch '^[0-9a-f]{40}$') { throw "invalid expected commit SHA for tag $Tag" }
  $actual = Get-DshTagCommitSha -Repository $Repository -Tag $Tag -Headers $Headers
  if ($null -eq $actual) {
    if ($AllowMissing) { return }
    throw "Git tag $Tag does not resolve to a commit"
  }
  if ($actual -cne $expected) {
    throw "Git tag $Tag resolves to $actual instead of $expected"
  }
}

function Get-DshReleasesByTag {
  param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][hashtable]$Headers
  )

  $matches = [Collections.Generic.List[object]]::new()
  for ($page = 1; $page -le 100; $page++) {
    $rawPage = Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/repos/$Repository/releases?per_page=100&page=$page"
    # Invoke-RestMethod can preserve a JSON array as one pipeline object. Piping
    # the assigned value flattens that one level before Count and filtering.
    $pageReleases = @($rawPage | ForEach-Object { $_ })
    foreach ($release in $pageReleases) {
      if ([string]$release.tag_name -ceq $Tag) { $matches.Add($release) }
    }
    if ($pageReleases.Count -lt 100) { return $matches.ToArray() }
  }
  throw 'GitHub Release pagination exceeded 100 pages'
}

function Get-DshUniqueReleaseForTag {
  param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][hashtable]$Headers
  )

  $releasesById = @{}
  foreach ($release in @(Get-DshReleasesByTag -Repository $Repository -Tag $Tag -Headers $Headers)) {
    $releaseId = [string]$release.id
    if ($releaseId -notmatch '^[0-9]+$') { throw "GitHub returned an invalid Release id for $Tag" }
    $releasesById[$releaseId] = $release
  }

  $published = Get-DshPublishedReleaseByTag -Repository $Repository -Tag $Tag -Headers $Headers
  if ($null -ne $published) {
    $publishedId = [string]$published.id
    if ($publishedId -notmatch '^[0-9]+$') { throw "GitHub returned an invalid published Release id for $Tag" }
    if ($releasesById.ContainsKey($publishedId) -and [bool]$releasesById[$publishedId].draft) {
      throw "Release $publishedId changed from Draft to public during inspection"
    }
    $releasesById[$publishedId] = $published
  }

  if ($releasesById.Count -gt 1) {
    throw "multiple Releases use tag $Tag; refusing to choose one"
  }
  if ($releasesById.Count -eq 0) { return $null }
  return @($releasesById.Values)[0]
}

function Assert-DshReleaseIdentity {
  param(
    [Parameter(Mandatory)][object]$Release,
    [Parameter(Mandatory)][string]$Tag,
    [string]$ReleaseId = ''
  )

  if ([string]$Release.tag_name -cne $Tag) {
    throw "Release $($Release.id) uses unexpected tag $($Release.tag_name)"
  }
  if ($ReleaseId -and [string]$Release.id -cne $ReleaseId) {
    throw "GitHub returned unexpected Release id $($Release.id) instead of $ReleaseId"
  }
}

function Test-DshReleaseIsDraft {
  param([Parameter(Mandatory)][object]$Release)

  return [bool]$Release.draft
}

function Assert-DshRemoteAssets {
  param(
    [Parameter(Mandatory)][object]$Release,
    [Parameter(Mandatory)][object]$AssetContext,
    [switch]$AllowMissing
  )

  $remoteAssets = @($Release.assets | ForEach-Object { $_ })
  $expectedAssets = $AssetContext.ExpectedAssets
  $missingNames = [Collections.Generic.List[string]]::new()

  foreach ($asset in $remoteAssets) {
    $name = [string]$asset.name
    if (-not $expectedAssets.Contains($name)) {
      throw "Release $($Release.id) contains unexpected asset: $name"
    }
  }

  foreach ($entry in $expectedAssets.GetEnumerator()) {
    $assetMatches = @($remoteAssets | Where-Object { [string]$_.name -ceq $entry.Key })
    if ($assetMatches.Count -eq 0) {
      if ($AllowMissing) {
        $missingNames.Add($entry.Key)
        continue
      }
      throw "Release $($Release.id) is missing asset: $($entry.Key)"
    }
    if ($assetMatches.Count -ne 1) {
      throw "Release $($Release.id) must contain exactly one $($entry.Key) asset"
    }

    $asset = $assetMatches[0]
    if ([string]$asset.state -cne 'uploaded') {
      throw "Release asset is not fully uploaded: $($entry.Key)"
    }
    if ([int64]$asset.size -ne [int64]$entry.Value.Length) {
      throw "Release asset size mismatch: $($entry.Key)"
    }
    if ([string]$asset.digest -cnotmatch '^sha256:[0-9a-fA-F]{64}$') {
      throw "Release asset has no SHA256 digest: $($entry.Key)"
    }
    if (([string]$asset.digest).ToLowerInvariant() -ne [string]$entry.Value.Digest) {
      throw "Release asset SHA256 mismatch: $($entry.Key)"
    }
  }

  if (-not $AllowMissing -and $remoteAssets.Count -ne $expectedAssets.Count) {
    throw "Release $($Release.id) must contain exactly $($expectedAssets.Count) assets"
  }
  return [pscustomobject]@{ MissingNames = $missingNames.ToArray() }
}

function Assert-DshCompletePublicAssets {
  param(
    [Parameter(Mandatory)][object]$Release,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][object]$AssetContext,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][hashtable]$Headers
  )

  Assert-DshReleaseIdentity -Release $Release -Tag $Tag
  if (Test-DshReleaseIsDraft -Release $Release) {
    throw "Release $($Release.id) is still a Draft"
  }

  $remoteAssets = @($Release.assets | ForEach-Object { $_ })
  if ($remoteAssets.Count -ne 2) {
    throw "public Release $Tag must contain exactly two assets"
  }
  $packageMatches = @($remoteAssets | Where-Object { [string]$_.name -ceq $AssetContext.PackageName })
  $sumsMatches = @($remoteAssets | Where-Object { [string]$_.name -ceq 'SHA256SUMS.txt' })
  if ($packageMatches.Count -ne 1 -or $sumsMatches.Count -ne 1) {
    throw "public Release $Tag is missing the package/checksum pair"
  }
  $packageAsset = $packageMatches[0]
  $sumsAsset = $sumsMatches[0]
  foreach ($asset in @($packageAsset, $sumsAsset)) {
    if ([string]$asset.state -cne 'uploaded' -or [int64]$asset.size -le 0) {
      throw "public Release asset is incomplete: $($asset.name)"
    }
    if ([string]$asset.digest -cnotmatch '^sha256:[0-9a-fA-F]{64}$') {
      throw "public Release asset has no SHA256 digest: $($asset.name)"
    }
    if ([string]$asset.id -notmatch '^[0-9]+$') {
      throw "public Release asset has an invalid id: $($asset.name)"
    }
  }

  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  $tempName = 'dsh-release-sums-' + [guid]::NewGuid().ToString('N') + '.txt'
  $remoteSumsPath = Join-Path $tempRoot $tempName
  try {
    $downloadHeaders = $Headers.Clone()
    $downloadHeaders.Accept = 'application/octet-stream'
    Invoke-WebRequest `
      -Headers $downloadHeaders `
      -Uri "https://api.github.com/repos/$Repository/releases/assets/$($sumsAsset.id)" `
      -OutFile $remoteSumsPath
    if ((Get-Item -LiteralPath $remoteSumsPath).Length -ne [int64]$sumsAsset.size) {
      throw 'published SHA256SUMS.txt size does not match its asset record'
    }
    $sumsDigest = 'sha256:' + (Get-FileHash -LiteralPath $remoteSumsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sumsDigest -ne ([string]$sumsAsset.digest).ToLowerInvariant()) {
      throw 'published SHA256SUMS.txt digest does not match its asset record'
    }
    $sumLines = @(Get-Content -LiteralPath $remoteSumsPath | Where-Object { $_.Trim() })
    $sumPattern = '^' + [regex]::Escape(([string]$packageAsset.digest).Substring(7)) + '  ' + [regex]::Escape($AssetContext.PackageName) + '$'
    if ($sumLines.Count -ne 1 -or $sumLines[0] -cnotmatch $sumPattern) {
      throw 'published SHA256SUMS.txt does not verify the published package'
    }
  } finally {
    if (Test-Path -LiteralPath $remoteSumsPath -PathType Leaf) {
      $resolvedPath = (Resolve-Path -LiteralPath $remoteSumsPath).Path
      $expectedPath = [IO.Path]::GetFullPath((Join-Path $tempRoot $tempName))
      if ($resolvedPath -cne $expectedPath -or $tempName -notmatch '^dsh-release-sums-[0-9a-f]{32}\.txt$') {
        throw "refusing to remove unexpected temporary path: $resolvedPath"
      }
      Remove-Item -LiteralPath $resolvedPath -Force
    }
  }
}

function Assert-DshCompletePublicRelease {
  param(
    [Parameter(Mandatory)][object]$Release,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][object]$AssetContext,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][hashtable]$Headers,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [ValidateSet('true', 'false')][string]$Prerelease = 'false',
    [ValidateSet('legacy', 'true', 'false')][string]$MakeLatest = 'legacy',
    [switch]$MatchLocal
  )

  $expectedTarget = $ExpectedCommit.ToLowerInvariant()
  $recordedTarget = ([string]$Release.target_commitish).ToLowerInvariant()
  if ($expectedTarget -notmatch '^[0-9a-f]{40}$' -or $recordedTarget -cne $expectedTarget) {
    throw "published Release $Tag target commit $recordedTarget does not match $expectedTarget"
  }

  Assert-DshCompletePublicAssets `
    -Release $Release `
    -Tag $Tag `
    -AssetContext $AssetContext `
    -Repository $Repository `
    -Headers $Headers
  if ([bool]$Release.prerelease -ne ($Prerelease -eq 'true')) {
    throw "published Release $Tag has the wrong prerelease state"
  }
  if ($MakeLatest -ne 'legacy') {
    $latest = Get-DshLatestRelease -Repository $Repository -Headers $Headers
    $isLatest = $null -ne $latest -and [string]$latest.id -ceq [string]$Release.id
    if ($MakeLatest -eq 'true' -and -not $isLatest) {
      throw "published Release $Tag is not the repository's Latest Release"
    }
    if ($MakeLatest -eq 'false' -and $isLatest) {
      throw "published Release $Tag unexpectedly became the repository's Latest Release"
    }
  }
  if ($MatchLocal) {
    Assert-DshRemoteAssets -Release $Release -AssetContext $AssetContext | Out-Null
  }
}

function Set-DshGitHubOutput {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Value
  )

  if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding utf8
  }
}
