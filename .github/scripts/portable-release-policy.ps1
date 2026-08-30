# Pure portable Release identity and allocation policy. Callers supply GitHub
# Release objects; this file performs no network or filesystem operations.
Set-StrictMode -Version Latest

$script:DshPortableSemverBody = '(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
$script:DshPortableVersionPattern = '^' + $script:DshPortableSemverBody + '$'
$script:DshPortableTagPattern = '^v(?<version>' + $script:DshPortableSemverBody + ')$'
$script:DshPortableAssetPattern = '^DeepSeek-Harness-win64-v(?<version>' + $script:DshPortableSemverBody + ')\.zip$'
$script:DshPortableMarkerPattern = '(?m)^<!-- portable-version: (?<version>' + $script:DshPortableSemverBody + ') -->\r?$'
$script:DshLegacyPortableTags = @('v1.0.0', 'v1.1.0', 'v1.2.0')

function Get-DshPortableAssetState {
  param([Parameter(Mandatory)][object]$Release)

  $assets = @($Release.assets | ForEach-Object { $_ })
  $zipStates = @()
  foreach ($asset in $assets) {
    $assetMatch = [regex]::Match([string]$asset.name, $script:DshPortableAssetPattern)
    if ($assetMatch.Success) {
      $version = [string]$assetMatch.Groups['version'].Value
      $zipStates += [pscustomobject]@{
        Asset = $asset
        Parsed = [System.Management.Automation.SemanticVersion]::Parse($version)
        Version = $version
      }
    }
  }
  $sums = @($assets | Where-Object { [string]$_.name -ceq 'SHA256SUMS.txt' })
  if ($assets.Count -ne 2 -or $zipStates.Count -ne 1 -or $sums.Count -ne 1) { return $null }
  foreach ($asset in @($zipStates[0].Asset, $sums[0])) {
    if ([string]$asset.state -cne 'uploaded' -or [int64]$asset.size -le 0 -or
      [string]$asset.digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$asset.id -notmatch '^[0-9]+$') {
      return $null
    }
  }
  return [pscustomobject]@{
    AssetName = [string]$zipStates[0].Asset.name
    Parsed = $zipStates[0].Parsed
    SumsAsset = $sums[0]
    Version = $zipStates[0].Version
    ZipAsset = $zipStates[0].Asset
  }
}

function Get-DshNextPortableVersion {
  param([AllowEmptyString()][Parameter(Mandatory)][string]$HighestVersion)

  if (-not $HighestVersion) { return '1.0.0' }
  $incrementPattern = '^(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)(?:-.+)?(?:\+.+)?$'
  $match = [regex]::Match($HighestVersion, $incrementPattern)
  if (-not $match.Success) { throw "cannot increment portable version: $HighestVersion" }
  $nextPatch = [System.Numerics.BigInteger]::Parse($match.Groups['patch'].Value) + 1
  return "$($match.Groups['major'].Value).$($match.Groups['minor'].Value).$nextPatch"
}

function Resolve-DshPortableReleasePolicy {
  param(
    [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Releases,
    [Parameter(Mandatory)][string]$DshVersion,
    [string]$ExpectedSourceTag = '',
    [string]$ExpectedSourceSha = ''
  )

  if ($DshVersion -cnotmatch $script:DshPortableVersionPattern) { throw "invalid dsh version: $DshVersion" }
  if ([bool]$ExpectedSourceTag -ne [bool]$ExpectedSourceSha -or
    ($ExpectedSourceSha -and $ExpectedSourceSha -cnotmatch '^[0-9a-fA-F]{40}$')) {
    throw 'expected upstream source tag and exact SHA must be supplied together'
  }
  $dshParsed = [System.Management.Automation.SemanticVersion]::Parse($DshVersion)
  $dshPrerelease = $null -ne $dshParsed.PreReleaseLabel
  $publicReleases = @($Releases | Where-Object { -not [bool]$_.draft })
  $completePortable = @()

  foreach ($release in $publicReleases) {
    $tag = [string]$release.tag_name
    $tagMatch = [regex]::Match($tag, $script:DshPortableTagPattern)
    if (-not $tagMatch.Success) { continue }
    $assetState = Get-DshPortableAssetState -Release $release
    if ($null -eq $assetState) {
      if ($tag -notin $script:DshLegacyPortableTags) {
        throw "published portable Release $tag has an incomplete asset set"
      }
      continue
    }
    $tagVersion = [string]$tagMatch.Groups['version'].Value
    $markerMatch = [regex]::Match([string]$release.body, $script:DshPortableMarkerPattern)
    if ($markerMatch.Success) {
      if ([string]$markerMatch.Groups['version'].Value -cne $tagVersion -or $assetState.Version -cne $tagVersion) {
        throw "published Release $tag has inconsistent portable version metadata"
      }
    } elseif ($tag -notin $script:DshLegacyPortableTags) {
      throw "published portable Release $tag has no portable-version marker"
    }
    $completePortable += [pscustomobject]@{
      AssetState = $assetState
      Parsed = [System.Management.Automation.SemanticVersion]::Parse($tagVersion)
      Release = $release
      Tag = $tag
      Version = $tagVersion
    }
  }

  foreach ($duplicate in @($completePortable | Group-Object Tag | Where-Object { $_.Count -gt 1 })) {
    throw "multiple public Releases use portable tag $($duplicate.Name)"
  }

  $dshMarkerPattern = '(?m)^<!-- dsh-version: ' + [regex]::Escape($DshVersion) + ' -->\r?$'
  $matching = @($publicReleases | Where-Object { [regex]::IsMatch([string]$_.body, $dshMarkerPattern) })
  $validatedMatches = @()
  foreach ($release in $matching) {
    $assetState = Get-DshPortableAssetState -Release $release
    $tag = [string]$release.tag_name
    if ($null -eq $assetState) { throw "published Release $tag has an incomplete portable asset set" }
    $portableVersion = [string]$assetState.Version
    $portableParsed = [System.Management.Automation.SemanticVersion]::Parse($portableVersion)
    $tagMatch = [regex]::Match($tag, $script:DshPortableTagPattern)
    $legacyTag = "dsh-v$DshVersion"
    if ($tagMatch.Success) {
      if ([string]$tagMatch.Groups['version'].Value -cne $portableVersion -or
        -not ([string]$release.body).Contains("<!-- portable-version: $portableVersion -->")) {
        throw "published Release $tag has inconsistent portable version metadata"
      }
    } elseif ($tag -cne $legacyTag -or $portableVersion -cne $DshVersion) {
      throw "published Release $tag does not use a supported portable tag"
    }
    $sourceTagMatch = [regex]::Match([string]$release.body, '(?m)^<!-- upstream-source-tag: (?<value>[^\r\n]+) -->\r?$')
    $sourceShaMatch = [regex]::Match([string]$release.body, '(?m)^<!-- upstream-source-sha: (?<value>[0-9a-fA-F]{40}) -->\r?$')
    if ($sourceTagMatch.Success -ne $sourceShaMatch.Success) {
      throw "published Release $tag has incomplete upstream source metadata"
    }
    if ($sourceTagMatch.Success -and $ExpectedSourceTag) {
      if ([string]$sourceTagMatch.Groups['value'].Value -cne $ExpectedSourceTag -or
        [string]$sourceShaMatch.Groups['value'].Value -cne $ExpectedSourceSha) {
        throw "published Release $tag records a different upstream source"
      }
    }
    $expectedPrerelease = $dshPrerelease -or $null -ne $portableParsed.PreReleaseLabel
    if ([bool]$release.prerelease -ne $expectedPrerelease) {
      throw "published Release $tag has the wrong prerelease state"
    }
    if ([string]$release.target_commitish -cnotmatch '^[0-9a-fA-F]{40}$') {
      throw "published Release $tag does not record an exact source commit"
    }
    $validatedMatches += [pscustomobject]@{
      AssetState = $assetState
      IsPortableTag = $tagMatch.Success
      Parsed = $portableParsed
      Release = $release
      Tag = $tag
      Version = $portableVersion
    }
  }

  if ($validatedMatches.Count -gt 0) {
    $selected = @($validatedMatches | Sort-Object Parsed, IsPortableTag -Descending | Select-Object -First 1)[0]
    $previous = @($completePortable | Where-Object { $_.Parsed -lt $selected.Parsed } | Sort-Object Parsed -Descending | Select-Object -First 1)
    return [pscustomobject]@{
      AlreadyPackaged = $true
      AssetName = [string]$selected.AssetState.AssetName
      AssetState = $selected.AssetState
      PortableVersion = [string]$selected.Version
      Prerelease = $dshPrerelease -or $null -ne $selected.Parsed.PreReleaseLabel
      PreviousPortableTag = if ($previous.Count -eq 1) { [string]$previous[0].Tag } else { '' }
      Release = $selected.Release
      ReleaseTag = [string]$selected.Tag
    }
  }

  $highest = @($completePortable | Sort-Object Parsed -Descending | Select-Object -First 1)
  $previousTag = if ($highest.Count -eq 1) { [string]$highest[0].Tag } else { '' }
  $highestVersion = if ($highest.Count -eq 1) { [string]$highest[0].Version } else { '' }
  $portableVersion = Get-DshNextPortableVersion -HighestVersion $highestVersion
  return [pscustomobject]@{
    AlreadyPackaged = $false
    AssetName = "DeepSeek-Harness-win64-v$portableVersion.zip"
    AssetState = $null
    PortableVersion = $portableVersion
    Prerelease = $dshPrerelease
    PreviousPortableTag = $previousTag
    Release = $null
    ReleaseTag = "v$portableVersion"
  }
}
