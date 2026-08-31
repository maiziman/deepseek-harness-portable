# Pure portable Release identity and allocation policy. Callers supply GitHub
# Release objects; this file performs no network or filesystem operations.
Set-StrictMode -Version Latest

$script:DshPortableSemverBody = '(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
$script:DshPortableVersionPattern = '^' + $script:DshPortableSemverBody + '$'
$script:DshPortableTagPattern = '^v(?<version>' + $script:DshPortableSemverBody + ')$'
$script:DshPortableAssetPattern = '^(?:CedarDSH-Desktop|DeepSeek-Harness)-win64-v(?<version>' + $script:DshPortableSemverBody + ')\.zip$'
$script:DshPortableMarkerPattern = '(?m)^<!-- portable-version: (?<version>' + $script:DshPortableSemverBody + ') -->\r?$'
$script:DshVersionMarkerPattern = '(?m)^<!-- dsh-version: (?<version>' + $script:DshPortableSemverBody + ') -->\r?$'
$script:DshSourceTagMarkerPattern = '(?m)^<!-- upstream-source-tag: (?<value>dsh-v' + $script:DshPortableSemverBody + ') -->\r?$'
$script:DshSourceShaMarkerPattern = '(?m)^<!-- upstream-source-sha: (?<value>[0-9a-f]{40}) -->\r?$'
$script:DshLegacyPortableAssets = @{
  'v1.0.0' = '0.1.1-rc.2'
  'v1.1.0' = '0.1.1-rc.2'
  'v1.2.0' = '0.1.1-rc.2'
}

function Get-DshUniqueHighestSemverRecord {
  param(
    [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Records,
    [Parameter(Mandatory)][string]$Description
  )

  if ($Records.Count -eq 0) { throw "$Description has no semantic versions" }
  $ordered = @($Records | Sort-Object Parsed -Descending)
  $highest = $ordered[0].Parsed
  $matches = @($Records | Where-Object { $_.Parsed.CompareTo($highest) -eq 0 })
  if ($matches.Count -ne 1) {
    throw "$Description has ambiguous highest semantic-version precedence"
  }
  return $matches[0]
}

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

function Get-DshCompletePortableReleases {
  param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Releases)

  $complete = @()
  foreach ($release in @($Releases | Where-Object { -not [bool]$_.draft })) {
    $tag = [string]$release.tag_name
    $tagMatch = [regex]::Match($tag, $script:DshPortableTagPattern)
    if (-not $tagMatch.Success) { continue }

    $assetState = Get-DshPortableAssetState -Release $release
    if ($null -eq $assetState) {
      throw "published portable Release $tag has an incomplete asset set"
    }

    $tagVersion = [string]$tagMatch.Groups['version'].Value
    $markerMatches = [regex]::Matches([string]$release.body, $script:DshPortableMarkerPattern)
    if ($script:DshLegacyPortableAssets.ContainsKey($tag)) {
      $expectedLegacyAssetVersion = [string]$script:DshLegacyPortableAssets[$tag]
      if ($assetState.Version -cne $expectedLegacyAssetVersion) {
        throw "historical portable Release $tag has unexpected ZIP version $($assetState.Version)"
      }
      if ($markerMatches.Count -gt 1 -or
        ($markerMatches.Count -eq 1 -and [string]$markerMatches[0].Groups['version'].Value -cne $tagVersion)) {
        throw "historical portable Release $tag has inconsistent portable-version markers"
      }
    } else {
      if ($markerMatches.Count -ne 1) {
        throw "published portable Release $tag must contain exactly one portable-version marker"
      }
      if ([string]$markerMatches[0].Groups['version'].Value -cne $tagVersion -or
        $assetState.Version -cne $tagVersion) {
        throw "published Release $tag has inconsistent portable version metadata"
      }
      $dshMarkerMatches = [regex]::Matches([string]$release.body, $script:DshVersionMarkerPattern)
      $sourceTagMatches = [regex]::Matches([string]$release.body, $script:DshSourceTagMarkerPattern)
      $sourceShaMatches = [regex]::Matches([string]$release.body, $script:DshSourceShaMarkerPattern)
      if ($dshMarkerMatches.Count -ne 1 -or $sourceTagMatches.Count -ne 1 -or $sourceShaMatches.Count -ne 1) {
        throw "published portable Release $tag has incomplete source identity markers"
      }
      if ([string]$sourceTagMatches[0].Groups['value'].Value -cne "dsh-v$([string]$dshMarkerMatches[0].Groups['version'].Value)") {
        throw "published portable Release $tag has inconsistent dsh source markers"
      }
      if ([string]$release.target_commitish -cnotmatch '^[0-9a-fA-F]{40}$') {
        throw "published portable Release $tag does not record an exact target commit"
      }
      $tagParsed = [System.Management.Automation.SemanticVersion]::Parse($tagVersion)
      if ([bool]$release.prerelease -ne ($null -ne $tagParsed.PreReleaseLabel)) {
        throw "published portable Release $tag has the wrong prerelease state"
      }
    }
    $complete += [pscustomobject]@{
      AssetState = $assetState
      Parsed = [System.Management.Automation.SemanticVersion]::Parse($tagVersion)
      Release = $release
      Tag = $tag
      Version = $tagVersion
    }
  }

  foreach ($duplicate in @($complete | Group-Object Tag | Where-Object { $_.Count -gt 1 })) {
    throw "multiple public Releases use portable tag $($duplicate.Name)"
  }
  return $complete
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
  $publicReleases = @($Releases | Where-Object { -not [bool]$_.draft })
  $completePortable = @(Get-DshCompletePortableReleases -Releases $Releases)

  $dshMarkerPattern = '(?m)^<!-- dsh-version: ' + [regex]::Escape($DshVersion) + ' -->\r?$'
  $matching = @($publicReleases | Where-Object { [regex]::IsMatch([string]$_.body, $dshMarkerPattern) })
  $validatedMatches = @()
  foreach ($release in $matching) {
    $tag = [string]$release.tag_name
    $dshMarkerMatches = [regex]::Matches([string]$release.body, $dshMarkerPattern)
    if ($dshMarkerMatches.Count -ne 1) {
      throw "published Release $tag must contain exactly one dsh-version marker for $DshVersion"
    }
    $tagMatch = [regex]::Match($tag, $script:DshPortableTagPattern)
    $legacyTag = "dsh-v$DshVersion"
    if ($tagMatch.Success) {
      $portableMatches = @($completePortable | Where-Object { $_.Tag -ceq $tag })
      if ($portableMatches.Count -ne 1) {
        throw "published Release $tag is not one complete portable Release"
      }
      $portableRecord = $portableMatches[0]
      $assetState = $portableRecord.AssetState
      $portableVersion = [string]$portableRecord.Version
      $portableParsed = $portableRecord.Parsed
    } else {
      $assetState = Get-DshPortableAssetState -Release $release
      if ($null -eq $assetState) { throw "published Release $tag has an incomplete portable asset set" }
      $portableVersion = [string]$assetState.Version
      if ($tag -cne $legacyTag -or $portableVersion -cne $DshVersion) {
        throw "published Release $tag does not use a supported portable tag"
      }
      $portableParsed = [System.Management.Automation.SemanticVersion]::Parse($portableVersion)
    }

    $sourceTagMatches = [regex]::Matches([string]$release.body, $script:DshSourceTagMarkerPattern)
    $sourceShaMatches = [regex]::Matches([string]$release.body, $script:DshSourceShaMarkerPattern)
    if ($sourceTagMatches.Count -gt 1 -or $sourceShaMatches.Count -gt 1 -or
      ($sourceTagMatches.Count -eq 1) -ne ($sourceShaMatches.Count -eq 1)) {
      throw "published Release $tag has incomplete upstream source metadata"
    }
    if ($ExpectedSourceTag) {
      if ($sourceTagMatches.Count -eq 0) {
        if ($tag -cne $legacyTag) {
          throw "published portable Release $tag is missing upstream source metadata"
        }
      } elseif ([string]$sourceTagMatches[0].Groups['value'].Value -cne $ExpectedSourceTag -or
        [string]$sourceShaMatches[0].Groups['value'].Value -cne $ExpectedSourceSha) {
        throw "published Release $tag records a different upstream source"
      }
    }
    $expectedPrerelease = $null -ne $portableParsed.PreReleaseLabel
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
    $selected = Get-DshUniqueHighestSemverRecord -Records $validatedMatches -Description 'matching portable Releases'
    $previousCandidates = @($completePortable | Where-Object { $_.Parsed -lt $selected.Parsed })
    $previousTag = ''
    if ($previousCandidates.Count -gt 0) {
      $previous = Get-DshUniqueHighestSemverRecord -Records $previousCandidates -Description 'previous portable Releases'
      $previousTag = [string]$previous.Tag
    }
    return [pscustomobject]@{
      AlreadyPackaged = $true
      AssetName = [string]$selected.AssetState.AssetName
      AssetState = $selected.AssetState
      PortableVersion = [string]$selected.Version
      Prerelease = $null -ne $selected.Parsed.PreReleaseLabel
      PreviousPortableTag = $previousTag
      Release = $selected.Release
      ReleaseTag = [string]$selected.Tag
    }
  }

  $previousTag = ''
  $highestVersion = ''
  if ($completePortable.Count -gt 0) {
    $highest = Get-DshUniqueHighestSemverRecord -Records $completePortable -Description 'complete portable Releases'
    $previousTag = [string]$highest.Tag
    $highestVersion = [string]$highest.Version
  }
  $portableVersion = Get-DshNextPortableVersion -HighestVersion $highestVersion
  return [pscustomobject]@{
    AlreadyPackaged = $false
    AssetName = "CedarDSH-Desktop-win64-v$portableVersion.zip"
    AssetState = $null
    PortableVersion = $portableVersion
    Prerelease = $false
    PreviousPortableTag = $previousTag
    Release = $null
    ReleaseTag = "v$portableVersion"
  }
}

function Assert-DshAutomaticPortableAllocationCurrent {
  param(
    [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Releases,
    [Parameter(Mandatory)][string]$DshVersion,
    [Parameter(Mandatory)][string]$ExpectedPortableVersion,
    [Parameter(Mandatory)][string]$ExpectedReleaseTag,
    [AllowEmptyString()][Parameter(Mandatory)][string]$ExpectedPreviousPortableCommit,
    [AllowEmptyString()][Parameter(Mandatory)][string]$ExpectedPreviousPortableTag,
    [Parameter(Mandatory)][string]$ExpectedSourceTag,
    [Parameter(Mandatory)][string]$ExpectedSourceSha,
    [switch]$AllowExactAlreadyPublic
  )

  $policy = Resolve-DshPortableReleasePolicy `
    -Releases $Releases `
    -DshVersion $DshVersion `
    -ExpectedSourceTag $ExpectedSourceTag `
    -ExpectedSourceSha $ExpectedSourceSha
  if ([bool]$ExpectedPreviousPortableTag -ne [bool]$ExpectedPreviousPortableCommit -or
    ($ExpectedPreviousPortableCommit -and $ExpectedPreviousPortableCommit -cnotmatch '^[0-9a-fA-F]{40}$')) {
    throw 'expected previous portable tag and exact commit must be supplied together'
  }
  if ($policy.AlreadyPackaged) {
    if ([string]$policy.ReleaseTag -ceq $ExpectedReleaseTag -and
      [string]$policy.PortableVersion -ceq $ExpectedPortableVersion) {
      if ($AllowExactAlreadyPublic) { return $policy }
      throw "portable Release $ExpectedReleaseTag became public while its Draft was staged"
    }
    throw "official dsh $DshVersion was packaged under another portable tag while this run was building"
  }
  if ([string]$policy.PreviousPortableTag -cne $ExpectedPreviousPortableTag -or
    [string]$policy.PortableVersion -cne $ExpectedPortableVersion -or
    [string]$policy.ReleaseTag -cne $ExpectedReleaseTag) {
    throw "portable version allocation changed while building: expected $ExpectedPreviousPortableTag -> $ExpectedReleaseTag, found $($policy.PreviousPortableTag) -> $($policy.ReleaseTag)"
  }
  return $policy
}

function Assert-DshManualPortableAllocationCurrent {
  param(
    [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Releases,
    [Parameter(Mandatory)][string]$CurrentTag,
    [Parameter(Mandatory)][string]$CurrentVersion,
    [AllowEmptyString()][Parameter(Mandatory)][string]$ExpectedPreviousPortableCommit,
    [AllowEmptyString()][Parameter(Mandatory)][string]$ExpectedPreviousPortableTag,
    [switch]$AllowExactAlreadyPublic
  )

  if ($CurrentVersion -cnotmatch $script:DshPortableVersionPattern -or $CurrentTag -cne "v$CurrentVersion") {
    throw "manual portable tag $CurrentTag does not match version $CurrentVersion"
  }
  if ([bool]$ExpectedPreviousPortableTag -ne [bool]$ExpectedPreviousPortableCommit -or
    ($ExpectedPreviousPortableCommit -and $ExpectedPreviousPortableCommit -cnotmatch '^[0-9a-fA-F]{40}$')) {
    throw 'expected previous portable tag and exact commit must be supplied together'
  }
  $complete = @(Get-DshCompletePortableReleases -Releases $Releases)
  $alreadyPublic = @($complete | Where-Object { $_.Tag -ceq $CurrentTag })
  if ($alreadyPublic.Count -gt 1) { throw 'manual portable tag has duplicate complete Releases' }
  if ($alreadyPublic.Count -eq 1) {
    if ($AllowExactAlreadyPublic) {
      return [pscustomobject]@{
        AlreadyPublic = $true
        PreviousPortableCommit = $ExpectedPreviousPortableCommit
        PreviousPortableTag = $ExpectedPreviousPortableTag
      }
    }
    throw "manual portable Release $CurrentTag became public while its Draft was staged"
  }

  $current = [System.Management.Automation.SemanticVersion]::Parse($CurrentVersion)
  $actualPrevious = ''
  if ($complete.Count -gt 0) {
    $highest = Get-DshUniqueHighestSemverRecord -Records $complete -Description 'complete portable Releases'
    if ($highest.Parsed -ge $current) {
      throw "manual portable version $CurrentTag is not newer than complete Release $($highest.Tag)"
    }
    $actualPrevious = [string]$highest.Tag
  }
  if ($actualPrevious -cne $ExpectedPreviousPortableTag) {
    throw "manual portable previous Release changed while building: expected '$ExpectedPreviousPortableTag', found '$actualPrevious'"
  }
  return [pscustomobject]@{
    AlreadyPublic = $false
    PreviousPortableCommit = $ExpectedPreviousPortableCommit
    PreviousPortableTag = $actualPrevious
  }
}
