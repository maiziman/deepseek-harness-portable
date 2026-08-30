#requires -Version 7.2

# Exercise the Release scripts against an in-memory GitHub API. The mock keeps
# the tests keyless and prevents accidental network or repository mutations.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stageScript = Join-Path $PSScriptRoot 'stage-release.ps1'
$finalizeScript = Join-Path $PSScriptRoot 'finalize-release.ps1'
$savedEnvironment = @{}
foreach ($name in @('GH_TOKEN', 'GITHUB_OUTPUT', 'GITHUB_RUN_ATTEMPT', 'GITHUB_RUN_ID')) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureName = 'dsh-release-scripts-test-' + [guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $tempRoot $fixtureName
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

$savedGlobalApi = Get-Variable -Name DshReleaseScriptsTestApi -Scope Global -ErrorAction SilentlyContinue
$hadSavedGlobalApi = $null -ne $savedGlobalApi
$savedGlobalApiValue = if ($hadSavedGlobalApi) { $savedGlobalApi.Value } else { $null }
$global:DshReleaseScriptsTestApi = [pscustomobject]@{
  ClientWrites = 0
  CommitLookups = [Collections.Generic.List[string]]::new()
  DeleteCalls = 0
  FailUploadCall = 0
  LatestId = ''
  NextAssetId = 500
  NextReleaseId = 100
  OutputIndex = 0
  PatchIds = [Collections.Generic.List[string]]::new()
  RaceCommit = ''
  RaceTarget = ''
  RaceTriggered = $false
  Refs = @{}
  Releases = [Collections.Generic.List[object]]::new()
  UploadCalls = 0
}

function Assert-Condition {
  param(
    [Parameter(Mandatory)][bool]$Condition,
    [Parameter(Mandatory)][string]$Message
  )

  if (-not $Condition) { throw "assertion failed: $Message" }
}

function Assert-Equal {
  param(
    [AllowNull()][object]$Expected,
    [AllowNull()][object]$Actual,
    [Parameter(Mandatory)][string]$Message
  )

  if ([string]$Expected -cne [string]$Actual) {
    throw "assertion failed: $Message (expected '$Expected', found '$Actual')"
  }
}

function Assert-Throws {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [Parameter(Mandatory)][string]$MessagePattern
  )

  $caught = $null
  try {
    & $Action
  } catch {
    $caught = $_
  }
  if ($null -eq $caught) { throw "expected failure matching: $MessagePattern" }
  if ([string]$caught.Exception.Message -notlike $MessagePattern) {
    throw "unexpected failure '$($caught.Exception.Message)'; expected: $MessagePattern"
  }
}

function New-MockHttpException {
  param(
    [Parameter(Mandatory)][int]$StatusCode,
    [Parameter(Mandatory)][string]$Message
  )

  $exception = [Exception]::new($Message)
  $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{
      StatusCode = $StatusCode
    })
  return $exception
}

function Get-MockReleaseById {
  param([Parameter(Mandatory)][string]$ReleaseId)

  $matches = @($global:DshReleaseScriptsTestApi.Releases | Where-Object { [string]$_.id -ceq $ReleaseId })
  if ($matches.Count -eq 0) { return $null }
  if ($matches.Count -ne 1) { throw "mock contains duplicate Release id $ReleaseId" }
  return $matches[0]
}

function Add-MockRelease {
  param(
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][bool]$Draft,
    [Parameter(Mandatory)][string]$Commit,
    [bool]$Prerelease = $false
  )

  $releaseId = $global:DshReleaseScriptsTestApi.NextReleaseId
  $global:DshReleaseScriptsTestApi.NextReleaseId++
  $release = [pscustomobject]@{
    assets = @()
    body = ''
    draft = $Draft
    html_url = "https://example.invalid/releases/$releaseId"
    id = $releaseId
    name = ''
    prerelease = $Prerelease
    tag_name = $Tag
    target_commitish = $Commit
  }
  $global:DshReleaseScriptsTestApi.Releases.Add($release)
  if (-not $Draft) { $global:DshReleaseScriptsTestApi.Refs[$Tag] = $Commit }
  return $release
}

function Add-MockAsset {
  param(
    [Parameter(Mandatory)][object]$Release,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$SourcePath
  )

  $assetId = $global:DshReleaseScriptsTestApi.NextAssetId
  $global:DshReleaseScriptsTestApi.NextAssetId++
  $asset = [pscustomobject]@{
    digest = 'sha256:' + (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    id = $assetId
    mock_source_path = $SourcePath
    name = $Name
    size = [int64](Get-Item -LiteralPath $SourcePath).Length
    state = 'uploaded'
  }
  $Release.assets = @($Release.assets) + $asset
  return $asset
}

function Add-CompleteMockRelease {
  param(
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][bool]$Draft,
    [Parameter(Mandatory)][string]$Commit,
    [Parameter(Mandatory)][string]$PackageName,
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$SumsPath
  )

  $release = Add-MockRelease -Tag $Tag -Draft $Draft -Commit $Commit
  Add-MockAsset -Release $release -Name $PackageName -SourcePath $PackagePath | Out-Null
  Add-MockAsset -Release $release -Name 'SHA256SUMS.txt' -SourcePath $SumsPath | Out-Null
  return $release
}

function Get-MockAssetById {
  param([Parameter(Mandatory)][string]$AssetId)

  $matches = [Collections.Generic.List[object]]::new()
  foreach ($release in $global:DshReleaseScriptsTestApi.Releases) {
    foreach ($asset in @($release.assets)) {
      if ([string]$asset.id -ceq $AssetId) { $matches.Add($asset) }
    }
  }
  if ($matches.Count -eq 0) { return $null }
  if ($matches.Count -ne 1) { throw "mock contains duplicate asset id $AssetId" }
  return $matches[0]
}

function New-MockOutputPath {
  $global:DshReleaseScriptsTestApi.OutputIndex++
  return Join-Path $fixtureRoot "github-output-$($global:DshReleaseScriptsTestApi.OutputIndex).txt"
}

function Read-MockOutputs {
  param([Parameter(Mandatory)][string]$Path)

  $values = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $values }
  foreach ($line in Get-Content -LiteralPath $Path) {
    $parts = $line -split '=', 2
    if ($parts.Count -ne 2) { throw "invalid GITHUB_OUTPUT line: $line" }
    $values[$parts[0]] = $parts[1]
  }
  return $values
}

function Invoke-MockStage {
  param(
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$PackageName,
    [Parameter(Mandatory)][string]$Commit,
    [Parameter(Mandatory)][string]$RunId,
    [switch]$RequireExistingTag
  )

  $outputPath = New-MockOutputPath
  $env:GITHUB_OUTPUT = $outputPath
  $env:GITHUB_RUN_ID = $RunId
  $env:GITHUB_RUN_ATTEMPT = '1'
  & $stageScript `
    -Repository 'owner/repository' `
    -Tag $Tag `
    -PackageName $PackageName `
    -AssetsDir $fixtureRoot `
    -TargetCommitish $Commit `
    -MakeLatest false `
    -RequireExistingTag:$RequireExistingTag | Out-Null
  return Read-MockOutputs -Path $outputPath
}

function Invoke-MockFinalize {
  param(
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$PackageName,
    [Parameter(Mandatory)][string]$ReleaseId,
    [Parameter(Mandatory)][string]$DraftTag,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [string]$ExpectedBodySha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    [string]$ExpectedNameSha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    [switch]$RequireExistingTag
  )

  $outputPath = New-MockOutputPath
  $env:GITHUB_OUTPUT = $outputPath
  & $finalizeScript `
    -Repository 'owner/repository' `
    -Tag $Tag `
    -PackageName $PackageName `
    -AssetsDir $fixtureRoot `
    -ReleaseId $ReleaseId `
    -DraftTag $DraftTag `
    -ExpectedCommit $ExpectedCommit `
    -ExpectedBodySha256 $ExpectedBodySha256 `
    -ExpectedNameSha256 $ExpectedNameSha256 `
    -MakeLatest false `
    -RequireExistingTag:$RequireExistingTag | Out-Null
  return Read-MockOutputs -Path $outputPath
}

# These functions intentionally shadow the network cmdlets for child script
# scopes. Any unmodelled request fails instead of reaching GitHub.
function Invoke-RestMethod {
  [CmdletBinding()]
  param(
    [string]$Method = 'Get',
    [hashtable]$Headers,
    [string]$Uri,
    [string]$ContentType,
    [string]$Body,
    [string]$InFile
  )

  if ($Method -eq 'Delete') {
    $global:DshReleaseScriptsTestApi.DeleteCalls++
    throw 'Release scripts must never issue DELETE requests'
  }

  if ($Method -eq 'Get') {
    if ($Uri -match '/releases/latest$') {
      $latest = Get-MockReleaseById -ReleaseId $global:DshReleaseScriptsTestApi.LatestId
      if ($null -eq $latest) { throw (New-MockHttpException -StatusCode 404 -Message 'Latest Release not found') }
      return $latest
    }
    if ($Uri -match '/commits/(?<tag>[^/?]+)$') {
      $tag = [uri]::UnescapeDataString($Matches.tag)
      $global:DshReleaseScriptsTestApi.CommitLookups.Add($tag)
      if (-not $global:DshReleaseScriptsTestApi.Refs.ContainsKey($tag)) {
        throw (New-MockHttpException -StatusCode 404 -Message "tag not found: $tag")
      }
      return [pscustomobject]@{ sha = $global:DshReleaseScriptsTestApi.Refs[$tag] }
    }
    if ($Uri -match '/releases/tags/(?<tag>[^/?]+)$') {
      $tag = [uri]::UnescapeDataString($Matches.tag)
      $matches = @($global:DshReleaseScriptsTestApi.Releases | Where-Object {
          -not [bool]$_.draft -and [string]$_.tag_name -ceq $tag
        })
      if ($matches.Count -eq 0) {
        throw (New-MockHttpException -StatusCode 404 -Message "Release tag not found: $tag")
      }
      if ($matches.Count -ne 1) { throw "mock contains duplicate public Release tag $tag" }
      return $matches[0]
    }
    if ($Uri -match '/releases/(?<releaseId>[0-9]+)$') {
      $release = Get-MockReleaseById -ReleaseId $Matches.releaseId
      if ($null -eq $release) {
        throw (New-MockHttpException -StatusCode 404 -Message "Release id not found: $($Matches.releaseId)")
      }
      return $release
    }
    if ($Uri -match '/releases\?') {
      return @($global:DshReleaseScriptsTestApi.Releases | ForEach-Object { $_ })
    }
    throw "unmodelled GitHub GET request: $Uri"
  }

  if ($Method -eq 'Post' -and $Uri -match '/releases/generate-notes$') {
    return [pscustomobject]@{ body = 'Generated body'; name = 'Generated name' }
  }

  if ($Method -eq 'Post' -and $Uri -match '/releases$') {
    $global:DshReleaseScriptsTestApi.ClientWrites++
    $payload = $Body | ConvertFrom-Json
    $conflicts = @($global:DshReleaseScriptsTestApi.Releases | Where-Object {
        [string]$_.tag_name -ceq [string]$payload.tag_name
      })
    if ($conflicts.Count -gt 0) {
      throw (New-MockHttpException -StatusCode 422 -Message 'Release tag already exists')
    }
    $release = Add-MockRelease `
      -Tag ([string]$payload.tag_name) `
      -Draft ([bool]$payload.draft) `
      -Commit ([string]$payload.target_commitish) `
      -Prerelease ([bool]$payload.prerelease)
    if ($null -ne $payload.PSObject.Properties['name']) {
      $release.name = [string]$payload.name
    }
    if ($null -ne $payload.PSObject.Properties['body']) {
      $release.body = [string]$payload.body
    }
    return $release
  }

  if ($Method -eq 'Post' -and $Uri -match '/releases/(?<releaseId>[0-9]+)/assets\?name=(?<name>[^&]+)') {
    $global:DshReleaseScriptsTestApi.ClientWrites++
    $global:DshReleaseScriptsTestApi.UploadCalls++
    if ($global:DshReleaseScriptsTestApi.FailUploadCall -eq $global:DshReleaseScriptsTestApi.UploadCalls) {
      throw 'simulated upload interruption'
    }
    $release = Get-MockReleaseById -ReleaseId $Matches.releaseId
    if ($null -eq $release) { throw "upload target Release does not exist: $($Matches.releaseId)" }
    $assetName = [uri]::UnescapeDataString($Matches.name)
    Add-MockAsset -Release $release -Name $assetName -SourcePath $InFile | Out-Null
    return [pscustomobject]@{ uploaded = $true }
  }

  if ($Method -eq 'Patch' -and $Uri -match '/releases/(?<releaseId>[0-9]+)$') {
    $global:DshReleaseScriptsTestApi.ClientWrites++
    $global:DshReleaseScriptsTestApi.PatchIds.Add([string]$Matches.releaseId)
    $release = Get-MockReleaseById -ReleaseId $Matches.releaseId
    if ($null -eq $release) { throw "PATCH target Release does not exist: $($Matches.releaseId)" }
    $payload = $Body | ConvertFrom-Json

    if ($global:DshReleaseScriptsTestApi.RaceTarget -and
        [string]$payload.tag_name -ceq $global:DshReleaseScriptsTestApi.RaceTarget -and
        -not $global:DshReleaseScriptsTestApi.RaceTriggered) {
      $global:DshReleaseScriptsTestApi.RaceTriggered = $true
      Add-MockRelease `
        -Tag $global:DshReleaseScriptsTestApi.RaceTarget `
        -Draft $false `
        -Commit $global:DshReleaseScriptsTestApi.RaceCommit | Out-Null
    }

    $conflicts = @($global:DshReleaseScriptsTestApi.Releases | Where-Object {
        [string]$_.id -cne [string]$release.id -and
        [string]$_.tag_name -ceq [string]$payload.tag_name
      })
    if ($conflicts.Count -gt 0) {
      throw (New-MockHttpException -StatusCode 422 -Message 'Release tag already exists during PATCH')
    }

    $targetTag = [string]$payload.tag_name
    if (-not $global:DshReleaseScriptsTestApi.Refs.ContainsKey($targetTag)) {
      $global:DshReleaseScriptsTestApi.Refs[$targetTag] = [string]$payload.target_commitish
    }
    $release.tag_name = $targetTag
    $release.target_commitish = [string]$payload.target_commitish
    if ($null -ne $payload.PSObject.Properties['body']) {
      $release.body = [string]$payload.body
    }
    $release.draft = [bool]$payload.draft
    $release.prerelease = [bool]$payload.prerelease
    if ($null -ne $payload.PSObject.Properties['name']) {
      $release.name = [string]$payload.name
    }
    if ([string]$payload.make_latest -eq 'true') {
      $global:DshReleaseScriptsTestApi.LatestId = [string]$release.id
    }
    return $release
  }

  throw "unmodelled GitHub request: $Method $Uri"
}

function Invoke-WebRequest {
  [CmdletBinding()]
  param(
    [hashtable]$Headers,
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][string]$OutFile
  )

  if ($Uri -notmatch '/releases/assets/(?<assetId>[0-9]+)$') {
    throw "unmodelled GitHub download request: $Uri"
  }
  $asset = Get-MockAssetById -AssetId $Matches.assetId
  if ($null -eq $asset) { throw "download asset does not exist: $($Matches.assetId)" }
  [IO.File]::Copy([string]$asset.mock_source_path, $OutFile, $true)
  return [pscustomobject]@{ StatusCode = 200 }
}

try {
  $packageName = 'dsh-model-capabilities-1.0.0.tgz'
  $packagePath = Join-Path $fixtureRoot $packageName
  $sumsPath = Join-Path $fixtureRoot 'SHA256SUMS.txt'
  [IO.File]::WriteAllText($packagePath, 'mock package bytes', [Text.UTF8Encoding]::new($false))
  $packageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText(
    $sumsPath,
    "$packageHash  $packageName`n",
    [Text.UTF8Encoding]::new($false)
  )

  $expectedCommit = '1111111111111111111111111111111111111111'
  $otherCommit = '2222222222222222222222222222222222222222'
  $env:GH_TOKEN = 'mock-token'

  $writesBeforeValidation = $global:DshReleaseScriptsTestApi.ClientWrites
  & $stageScript `
    -Repository 'owner/repository' `
    -Tag 'plugin-v-validate-only' `
    -PackageName $packageName `
    -AssetsDir $fixtureRoot `
    -ValidateOnly | Out-Null
  & $finalizeScript `
    -Repository 'owner/repository' `
    -Tag 'plugin-v-validate-only' `
    -PackageName $packageName `
    -AssetsDir $fixtureRoot `
    -ValidateOnly | Out-Null
  Assert-Equal $writesBeforeValidation $global:DshReleaseScriptsTestApi.ClientWrites 'ValidateOnly must not call GitHub'
  Write-Output 'PASS local ValidateOnly is keyless and read-only'

  $latest = Add-CompleteMockRelease `
    -Tag 'v-portable-latest' `
    -Draft $false `
    -Commit $otherCommit `
    -PackageName $packageName `
    -PackagePath $packagePath `
    -SumsPath $sumsPath
  $global:DshReleaseScriptsTestApi.LatestId = [string]$latest.id
  $public = Add-CompleteMockRelease `
    -Tag 'plugin-v-public' `
    -Draft $false `
    -Commit $expectedCommit `
    -PackageName $packageName `
    -PackagePath $packagePath `
    -SumsPath $sumsPath
  $publicAssetIds = @($public.assets | ForEach-Object { [string]$_.id }) -join ','
  $writesBeforePublicSkip = $global:DshReleaseScriptsTestApi.ClientWrites
  $publicOutputs = Invoke-MockStage `
    -Tag 'plugin-v-public' `
    -PackageName $packageName `
    -Commit $expectedCommit `
    -RunId '2001'
  Assert-Equal 'false' $publicOutputs.should_publish 'complete public Release must skip staging'
  Assert-Equal 'true' $publicOutputs.skipped 'complete public Release must report skipped'
  Assert-Equal $writesBeforePublicSkip $global:DshReleaseScriptsTestApi.ClientWrites 'public skip must not mutate GitHub'
  Assert-Equal $publicAssetIds (@($public.assets | ForEach-Object { [string]$_.id }) -join ',') 'public assets must remain untouched'
  Assert-Condition (-not [bool]$public.draft) 'public Release must remain public'
  Write-Output 'PASS complete public Release is verified and skipped without writes'

  $staleTarget = Add-CompleteMockRelease `
    -Tag 'plugin-v-stale-target' `
    -Draft $false `
    -Commit $expectedCommit `
    -PackageName $packageName `
    -PackagePath $packagePath `
    -SumsPath $sumsPath
  $staleTarget.target_commitish = $otherCommit
  Assert-Throws -MessagePattern '*target commit*does not match*' -Action {
    Invoke-MockStage `
      -Tag 'plugin-v-stale-target' `
      -PackageName $packageName `
      -Commit $expectedCommit `
      -RunId '2002' | Out-Null
  }
  Write-Output 'PASS public skip rejects a Release recorded for a stale target commit'

  $notesOutputPath = New-MockOutputPath
  $env:GITHUB_OUTPUT = $notesOutputPath
  $env:GITHUB_RUN_ID = '2008'
  $env:GITHUB_RUN_ATTEMPT = '1'
  & $stageScript `
    -Repository 'owner/repository' `
    -Tag 'plugin-v-generated-notes' `
    -PackageName $packageName `
    -AssetsDir $fixtureRoot `
    -TargetCommitish $expectedCommit `
    -ReleaseName 'Portable release' `
    -Body 'Identity prefix' `
    -PreviousTagName 'v1.2.0' `
    -GenerateReleaseNotes `
    -AppendGeneratedReleaseNotes `
    -MakeLatest false | Out-Null
  $notesOutputs = Read-MockOutputs -Path $notesOutputPath
  $notesDraft = Get-MockReleaseById -ReleaseId $notesOutputs.release_id
  Assert-Equal "Identity prefix`n`nGenerated body" $notesDraft.body 'generated notes must follow the immutable identity prefix'
  Assert-Condition ([string]$notesOutputs.body_sha256 -match '^[0-9a-f]{64}$') 'stage must output the complete body digest'
  Write-Output 'PASS generated changelog is appended after the verified Release identity prefix'

  $publicNotes = Add-CompleteMockRelease `
    -Tag 'plugin-v-public-notes' `
    -Draft $false `
    -Commit $expectedCommit `
    -PackageName $packageName `
    -PackagePath $packagePath `
    -SumsPath $sumsPath
  $publicNotes.name = 'Portable release'
  $publicNotes.body = "Identity prefix`n`nHistorical generated body"
  $publicNotesOutputPath = New-MockOutputPath
  $env:GITHUB_OUTPUT = $publicNotesOutputPath
  $env:GITHUB_RUN_ID = '2009'
  $env:GITHUB_RUN_ATTEMPT = '1'
  $writesBeforeNotesSkip = $global:DshReleaseScriptsTestApi.ClientWrites
  & $stageScript `
    -Repository 'owner/repository' `
    -Tag 'plugin-v-public-notes' `
    -PackageName $packageName `
    -AssetsDir $fixtureRoot `
    -TargetCommitish $expectedCommit `
    -ReleaseName 'Portable release' `
    -Body 'Identity prefix' `
    -PreviousTagName 'v1.2.0' `
    -GenerateReleaseNotes `
    -AppendGeneratedReleaseNotes `
    -MakeLatest false | Out-Null
  $publicNotesOutputs = Read-MockOutputs -Path $publicNotesOutputPath
  Assert-Equal 'true' $publicNotesOutputs.skipped 'public Release with generated notes must remain idempotent'
  Assert-Equal $writesBeforeNotesSkip $global:DshReleaseScriptsTestApi.ClientWrites 'generated-notes public skip must not mutate GitHub'
  Write-Output 'PASS generated-notes public rerun verifies the fixed identity prefix and skips'

  $refConflictTag = 'plugin-v-ref-conflict'
  $global:DshReleaseScriptsTestApi.Refs[$refConflictTag] = $otherCommit
  $writesBeforeRefConflict = $global:DshReleaseScriptsTestApi.ClientWrites
  Assert-Throws -MessagePattern '*resolves to*instead of*' -Action {
    Invoke-MockStage `
      -Tag $refConflictTag `
      -PackageName $packageName `
      -Commit $expectedCommit `
      -RunId '2002' | Out-Null
  }
  Assert-Equal $writesBeforeRefConflict $global:DshReleaseScriptsTestApi.ClientWrites 'wrong existing tag must fail before Draft creation'
  Assert-Condition (@($global:DshReleaseScriptsTestApi.Releases | Where-Object {
        [string]$_.tag_name -like "$refConflictTag-draft-*"
      }).Count -eq 0) 'tag conflict must not leave a Draft'
  Write-Output 'PASS existing tag commit conflict fails before any write'

  $missingRequiredTag = 'plugin-v-required-tag-missing'
  Assert-Throws -MessagePattern '*does not resolve to a commit*' -Action {
    Invoke-MockStage `
      -Tag $missingRequiredTag `
      -PackageName $packageName `
      -Commit $expectedCommit `
      -RunId '2010' `
      -RequireExistingTag | Out-Null
  }
  Assert-Condition (@($global:DshReleaseScriptsTestApi.Releases | Where-Object {
        [string]$_.tag_name -like "$missingRequiredTag-draft-*"
      }).Count -eq 0) 'missing required trigger tag must fail before Draft creation'
  Write-Output 'PASS tag-triggered staging treats a deleted trigger tag as cancellation'

  $recoverTag = 'plugin-v-recover'
  $global:DshReleaseScriptsTestApi.FailUploadCall = $global:DshReleaseScriptsTestApi.UploadCalls + 2
  Assert-Throws -MessagePattern '*simulated upload interruption*' -Action {
    Invoke-MockStage `
      -Tag $recoverTag `
      -PackageName $packageName `
      -Commit $expectedCommit `
      -RunId '2003' | Out-Null
  }
  $orphanMatches = @($global:DshReleaseScriptsTestApi.Releases | Where-Object {
      [bool]$_.draft -and [string]$_.tag_name -like "$recoverTag-draft-2003-*"
    })
  Assert-Condition ($orphanMatches.Count -eq 1) 'upload interruption must leave one isolated Draft'
  $orphan = $orphanMatches[0]
  Assert-Condition (@($orphan.assets).Count -eq 1) 'interrupted Draft must retain only the completed upload'
  Assert-Condition (-not $global:DshReleaseScriptsTestApi.Refs.ContainsKey($recoverTag)) 'interrupted Draft must not create the public tag'

  $global:DshReleaseScriptsTestApi.FailUploadCall = 0
  $readyOutputs = Invoke-MockStage `
    -Tag $recoverTag `
    -PackageName $packageName `
    -Commit $expectedCommit `
    -RunId '2004'
  Assert-Equal 'true' $readyOutputs.should_publish 'new isolated Draft must be ready to publish'
  $ready = Get-MockReleaseById -ReleaseId $readyOutputs.release_id
  Assert-Condition ($null -ne $ready) 'stage output must identify an existing exact Release id'
  Assert-Equal $readyOutputs.draft_tag $ready.tag_name 'stage output must identify the exact isolated Draft tag'
  Assert-Condition (@($ready.assets).Count -eq 2) 'new run must stage the complete asset pair'
  Assert-Condition ([string]$ready.id -cne [string]$orphan.id) 'new run must not reuse the interrupted Draft id'
  Assert-Condition ([string]$ready.tag_name -cne [string]$orphan.tag_name) 'new run must use a new temporary tag'
  Write-Output 'PASS interrupted upload leaves an isolated Draft and does not block a new run'

  $decoy = Add-CompleteMockRelease `
    -Tag "$recoverTag-draft-decoy" `
    -Draft $true `
    -Commit $expectedCommit `
    -PackageName $packageName `
    -PackagePath $packagePath `
    -SumsPath $sumsPath
  $readyDraftTag = [string]$ready.tag_name
  $patchesBeforeExactPublish = $global:DshReleaseScriptsTestApi.PatchIds.Count
  $commitLookupsBeforeExactPublish = $global:DshReleaseScriptsTestApi.CommitLookups.Count
  $publishOutputs = Invoke-MockFinalize `
    -Tag $recoverTag `
    -PackageName $packageName `
    -ReleaseId ([string]$ready.id) `
    -DraftTag $readyDraftTag `
    -ExpectedCommit $expectedCommit
  Assert-Equal 'true' $publishOutputs.published 'finalizer must report exact Draft publication'
  Assert-Condition ($global:DshReleaseScriptsTestApi.PatchIds.Count -eq $patchesBeforeExactPublish + 1) 'finalizer must issue one PATCH'
  Assert-Equal ([string]$ready.id) $global:DshReleaseScriptsTestApi.PatchIds[$global:DshReleaseScriptsTestApi.PatchIds.Count - 1] 'PATCH must address the supplied Release id'
  $finalizerCommitLookups = @(
    $global:DshReleaseScriptsTestApi.CommitLookups |
      Select-Object -Skip $commitLookupsBeforeExactPublish
  )
  Assert-Condition ($finalizerCommitLookups.Count -eq 3) 'finalizer must check the target tag twice before PATCH and once after PATCH'
  Assert-Condition (@($finalizerCommitLookups | Where-Object { $_ -cne $recoverTag }).Count -eq 0) 'all finalizer tag checks must address the public tag'
  Assert-Equal $recoverTag $ready.tag_name 'exact Draft must receive the public tag'
  Assert-Condition (-not [bool]$ready.draft) 'exact Draft must become public'
  Assert-Equal $expectedCommit $global:DshReleaseScriptsTestApi.Refs[$recoverTag] 'published tag must resolve to the expected commit'
  Assert-Condition ([bool]$decoy.draft) 'unselected complete Draft must remain private'
  Assert-Condition ([bool]$orphan.draft) 'interrupted Draft must remain private'
  Assert-Equal ([string]$latest.id) $global:DshReleaseScriptsTestApi.LatestId 'MakeLatest=false must preserve the portable Latest Release'
  Write-Output 'PASS finalizer publishes only the exact Release id and preserves Latest=false'

  $writesBeforeFinalizeSkip = $global:DshReleaseScriptsTestApi.ClientWrites
  $repeatOutputs = Invoke-MockFinalize `
    -Tag $recoverTag `
    -PackageName $packageName `
    -ReleaseId ([string]$ready.id) `
    -DraftTag $readyDraftTag `
    -ExpectedCommit $expectedCommit
  Assert-Equal 'true' $repeatOutputs.skipped 'finalizer rerun must skip an already complete public Release'
  Assert-Equal $writesBeforeFinalizeSkip $global:DshReleaseScriptsTestApi.ClientWrites 'finalizer public skip must be read-only'
  Write-Output 'PASS finalizer rerun verifies and skips the exact public Release'

  $mutatedTag = 'plugin-v-mutated-draft'
  $mutatedOutputs = Invoke-MockStage `
    -Tag $mutatedTag `
    -PackageName $packageName `
    -Commit $expectedCommit `
    -RunId '2005'
  $mutated = Get-MockReleaseById -ReleaseId $mutatedOutputs.release_id
  $mutatedDraftTag = [string]$mutated.tag_name
  $mutated.target_commitish = $otherCommit
  $patchesBeforeMutationCheck = $global:DshReleaseScriptsTestApi.PatchIds.Count
  Assert-Throws -MessagePattern '*target commit changed*' -Action {
    Invoke-MockFinalize `
      -Tag $mutatedTag `
      -PackageName $packageName `
      -ReleaseId ([string]$mutated.id) `
      -DraftTag $mutatedDraftTag `
      -ExpectedCommit $expectedCommit | Out-Null
  }
  Assert-Equal $patchesBeforeMutationCheck $global:DshReleaseScriptsTestApi.PatchIds.Count 'mutated Draft commit must fail before PATCH'
  Assert-Condition ([bool]$mutated.draft) 'commit-mismatched Draft must remain private'
  Assert-Equal $mutatedDraftTag $mutated.tag_name 'commit-mismatched Draft tag must remain isolated'
  Write-Output 'PASS ExpectedCommit rejects a concurrently edited Draft before publication'

  $bodyTag = 'plugin-v-mutated-body'
  $bodyOutputs = Invoke-MockStage `
    -Tag $bodyTag `
    -PackageName $packageName `
    -Commit $expectedCommit `
    -RunId '2007'
  $bodyDraft = Get-MockReleaseById -ReleaseId $bodyOutputs.release_id
  $bodyDraftTag = [string]$bodyDraft.tag_name
  $bodyDraft.body = 'concurrently changed body'
  Assert-Throws -MessagePattern '*body changed*' -Action {
    Invoke-MockFinalize `
      -Tag $bodyTag `
      -PackageName $packageName `
      -ReleaseId ([string]$bodyDraft.id) `
      -DraftTag $bodyDraftTag `
      -ExpectedCommit $expectedCommit `
      -ExpectedBodySha256 $bodyOutputs.body_sha256 | Out-Null
  }
  Assert-Condition ([bool]$bodyDraft.draft) 'body-mismatched Draft must remain private'
  Write-Output 'PASS ExpectedBodySha256 rejects a concurrently edited Draft before publication'

  $nameTag = 'plugin-v-mutated-name'
  $nameOutputs = Invoke-MockStage `
    -Tag $nameTag `
    -PackageName $packageName `
    -Commit $expectedCommit `
    -RunId '2011'
  $nameDraft = Get-MockReleaseById -ReleaseId $nameOutputs.release_id
  $nameDraftTag = [string]$nameDraft.tag_name
  $nameDraft.name = 'concurrently changed name'
  Assert-Throws -MessagePattern '*name changed*' -Action {
    Invoke-MockFinalize `
      -Tag $nameTag `
      -PackageName $packageName `
      -ReleaseId ([string]$nameDraft.id) `
      -DraftTag $nameDraftTag `
      -ExpectedCommit $expectedCommit `
      -ExpectedNameSha256 $nameOutputs.name_sha256 | Out-Null
  }
  Assert-Condition ([bool]$nameDraft.draft) 'name-mismatched Draft must remain private'
  Write-Output 'PASS ExpectedNameSha256 rejects a concurrently edited Draft before publication'

  $revokedTag = 'plugin-v-revoked-trigger'
  $global:DshReleaseScriptsTestApi.Refs[$revokedTag] = $expectedCommit
  $revokedOutputs = Invoke-MockStage `
    -Tag $revokedTag `
    -PackageName $packageName `
    -Commit $expectedCommit `
    -RunId '2012' `
    -RequireExistingTag
  $revokedDraft = Get-MockReleaseById -ReleaseId $revokedOutputs.release_id
  $revokedDraftTag = [string]$revokedDraft.tag_name
  $global:DshReleaseScriptsTestApi.Refs.Remove($revokedTag)
  $patchesBeforeRevocation = $global:DshReleaseScriptsTestApi.PatchIds.Count
  Assert-Throws -MessagePattern '*does not resolve to a commit*' -Action {
    Invoke-MockFinalize `
      -Tag $revokedTag `
      -PackageName $packageName `
      -ReleaseId ([string]$revokedDraft.id) `
      -DraftTag $revokedDraftTag `
      -ExpectedCommit $expectedCommit `
      -ExpectedNameSha256 $revokedOutputs.name_sha256 `
      -RequireExistingTag | Out-Null
  }
  Assert-Equal $patchesBeforeRevocation $global:DshReleaseScriptsTestApi.PatchIds.Count 'deleted trigger tag must fail before PATCH'
  Assert-Condition ([bool]$revokedDraft.draft) 'revoked tag must leave the isolated Draft private'
  Write-Output 'PASS tag-triggered finalization treats trigger-tag deletion as cancellation'

  $raceTag = 'plugin-v-release-race'
  $raceOutputs = Invoke-MockStage `
    -Tag $raceTag `
    -PackageName $packageName `
    -Commit $expectedCommit `
    -RunId '2006'
  $racingDraft = Get-MockReleaseById -ReleaseId $raceOutputs.release_id
  $racingDraftTag = [string]$racingDraft.tag_name
  $global:DshReleaseScriptsTestApi.RaceTarget = $raceTag
  $global:DshReleaseScriptsTestApi.RaceCommit = $otherCommit
  $global:DshReleaseScriptsTestApi.RaceTriggered = $false
  Assert-Throws -MessagePattern '*Release tag already exists during PATCH*' -Action {
    Invoke-MockFinalize `
      -Tag $raceTag `
      -PackageName $packageName `
      -ReleaseId ([string]$racingDraft.id) `
      -DraftTag $racingDraftTag `
      -ExpectedCommit $expectedCommit | Out-Null
  }
  Assert-Condition $global:DshReleaseScriptsTestApi.RaceTriggered 'mock must inject the target Release at PATCH time'
  Assert-Condition ([bool]$racingDraft.draft) 'conflicting PATCH must leave the selected Draft private'
  Assert-Equal $racingDraftTag $racingDraft.tag_name 'conflicting PATCH must preserve the temporary tag'
  $racePublic = @($global:DshReleaseScriptsTestApi.Releases | Where-Object {
      -not [bool]$_.draft -and [string]$_.tag_name -ceq $raceTag
    })
  Assert-Condition ($racePublic.Count -eq 1) 'concurrent public Release must remain present'
  Assert-Condition ($global:DshReleaseScriptsTestApi.DeleteCalls -eq 0) 'no failure path may issue DELETE'
  Write-Output 'PASS target Release race fails closed without deleting either Release'

  Write-Output 'PASS all release script mock tests'
} finally {
  foreach ($name in $savedEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
  }
  if (-not $hadSavedGlobalApi) {
    Remove-Variable -Name DshReleaseScriptsTestApi -Scope Global -ErrorAction SilentlyContinue
  } else {
    Set-Variable -Name DshReleaseScriptsTestApi -Scope Global -Value $savedGlobalApiValue
  }

  if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
    $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
    $expectedFixture = [IO.Path]::GetFullPath((Join-Path $tempRoot $fixtureName))
    $comparison = if ($IsWindows) {
      [StringComparison]::OrdinalIgnoreCase
    } else {
      [StringComparison]::Ordinal
    }
    $tempPrefix = $tempRoot.TrimEnd(
      [IO.Path]::DirectorySeparatorChar,
      [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.Equals($expectedFixture, $comparison) -or
        -not $resolvedFixture.StartsWith($tempPrefix, $comparison) -or
        $fixtureName -notmatch '^dsh-release-scripts-test-[0-9a-f]{32}$') {
      throw "refusing to remove unexpected test fixture: $resolvedFixture"
    }
    [IO.Directory]::Delete($resolvedFixture, $true)
  }
}
