# Fail closed when pnpm discovers an unreviewed dependency lifecycle script.
Set-StrictMode -Version Latest

function Assert-DshPnpmPendingBuildsReviewed {
  param([Parameter(Mandatory)][string]$TargetDirectory)

  $nodeModules = Join-Path $TargetDirectory 'node_modules'
  $metadataPath = Join-Path $nodeModules '.modules.yaml'
  if (-not (Test-Path -LiteralPath $nodeModules -PathType Container) -or
    -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw "pnpm could not report ignored builds and has no module metadata in $TargetDirectory"
  }
  try {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
  } catch {
    throw "pnpm module metadata is not the expected JSON document in ${TargetDirectory}: $($_.Exception.Message)"
  }
  $pendingProperty = $metadata.PSObject.Properties['pendingBuilds']
  if ($null -eq $pendingProperty) { throw "pnpm module metadata has no pendingBuilds record in $TargetDirectory" }
  $pending = @($pendingProperty.Value | ForEach-Object { [string]$_ })
  $allowBuildsProperty = $metadata.PSObject.Properties['allowBuilds']
  if ($null -eq $allowBuildsProperty -or $null -eq $allowBuildsProperty.Value) {
    throw "pnpm module metadata has no allowBuilds record in $TargetDirectory"
  }
  $reviewedNames = @($allowBuildsProperty.Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
  $unreviewed = @($pending | Where-Object {
    $locator = $_
    -not @($reviewedNames | Where-Object {
      $locator.StartsWith("${_}@", [StringComparison]::Ordinal)
    }).Count
  })
  if ($unreviewed.Count -gt 0) {
    throw "pnpm blocked an unreviewed dependency lifecycle script in ${TargetDirectory}: $($unreviewed -join ', ')"
  }
}

function Assert-DshPnpmBuildScriptsComplete {
  param(
    [Parameter(Mandatory)][string]$NodePath,
    [Parameter(Mandatory)][string]$PnpmCjsPath,
    [Parameter(Mandatory)][string]$TargetDirectory
  )

  $output = @(& $NodePath $PnpmCjsPath --dir $TargetDirectory ignored-builds 2>&1 | ForEach-Object { [string]$_ })
  $exitCode = $LASTEXITCODE
  $text = ($output -join "`n").Trim()
  if ($exitCode -ne 0) { throw "pnpm ignored-builds failed in $TargetDirectory (exit $exitCode): $text" }
  if ($text -cmatch '(?m)^Automatically ignored builds during installation:\r?$' -and
    $text -cmatch '(?m)^  None\r?$') { return }
  if ($text -cmatch '\AAutomatically ignored builds during installation:\r?\n  Cannot identify as no node_modules found(?:\r?\n|\z)') {
    Assert-DshPnpmPendingBuildsReviewed -TargetDirectory $TargetDirectory
    return
  }
  throw "pnpm blocked an unreviewed dependency lifecycle script in ${TargetDirectory}:`n$text"
}

function Get-DshPnpmFileBuildSelector {
  param(
    [Parameter(Mandatory)][string]$PackageName,
    [Parameter(Mandatory)][string]$TargetDirectory,
    [Parameter(Mandatory)][string]$ArchivePath
  )

  $target = [IO.Path]::GetFullPath($TargetDirectory)
  $archive = [IO.Path]::GetFullPath($ArchivePath)
  $locator = [IO.Path]::GetRelativePath($target, $archive).Replace('\', '/')
  return "${PackageName}@file:$locator"
}
