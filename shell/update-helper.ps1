param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Install')]
  [string]$Mode,
  [string]$RootPath,
  [string]$StagedRootPath,
  [string]$WorkPath,
  [int]$ParentProcessId = 0,
  [switch]$SkipRestart
)

$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Value) {
  return [IO.Path]::GetFullPath($Value).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-ChildPath([string]$Parent, [string]$Child, [string]$Label) {
  $parentFull = Get-FullPath $Parent
  $childFull = Get-FullPath $Child
  $prefix = $parentFull + [IO.Path]::DirectorySeparatorChar
  if (-not $childFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label escaped $parentFull"
  }
}

function Get-OwnedEntries($Manifest, [string]$Label) {
  $entries = @($Manifest.ownedTopLevelEntries)
  if ($entries.Count -eq 0) { throw "$Label manifest has no ownedTopLevelEntries" }
  $seen = @{}
  foreach ($entryValue in $entries) {
    $entry = [string]$entryValue
    if ([string]::IsNullOrWhiteSpace($entry) -or [IO.Path]::GetFileName($entry) -cne $entry -or $entry -in @('.', '..')) {
      throw "$Label manifest owns invalid entry '$entry'"
    }
    if ($entry -in @('dsh-home', 'workspace', '.cedardsh-update')) { throw "$Label manifest owns preserved entry '$entry'" }
    if ($seen.ContainsKey($entry)) { throw "$Label manifest owns duplicate entry '$entry'" }
    $seen[$entry] = $true
  }
  return @($entries | ForEach-Object { [string]$_ })
}

function Write-UpdateLog([string]$Root, [string]$Message) {
  $logDirectory = Join-Path $Root 'dsh-home\logs'
  New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
  Add-Content -LiteralPath (Join-Path $logDirectory 'update.log') `
    -Value "$(Get-Date -Format o) $Message" -Encoding utf8
}

function Remove-UpdatePath([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return }

  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    if ($item.PSIsContainer) {
      [IO.Directory]::Delete($item.FullName, $false)
    } else {
      [IO.File]::Delete($item.FullName)
    }
    return
  }

  if (-not $item.PSIsContainer) {
    [IO.File]::Delete($item.FullName)
    return
  }

  foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
    Remove-UpdatePath $child.FullName
  }
  [IO.Directory]::Delete($item.FullName, $false)
}

if ([string]::IsNullOrWhiteSpace($RootPath) -or [string]::IsNullOrWhiteSpace($StagedRootPath) `
    -or [string]::IsNullOrWhiteSpace($WorkPath) -or $ParentProcessId -le 0) {
  throw 'install mode requires RootPath, StagedRootPath, WorkPath, and ParentProcessId'
}

$root = Get-FullPath $RootPath
$stagedRoot = Get-FullPath $StagedRootPath
$work = Get-FullPath $WorkPath
$updatesRoot = Get-FullPath (Join-Path $root '.cedardsh-update')
Assert-ChildPath $updatesRoot $work 'update work directory'
Assert-ChildPath $work $stagedRoot 'staged package'
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "portable root is missing: $root" }
if (-not (Test-Path -LiteralPath $stagedRoot -PathType Container)) { throw "staged package is missing: $stagedRoot" }

$currentManifest = Get-Content -Raw -LiteralPath (Join-Path $root 'manifest.json') | ConvertFrom-Json
$nextManifest = Get-Content -Raw -LiteralPath (Join-Path $stagedRoot 'manifest.json') | ConvertFrom-Json
$currentEntries = Get-OwnedEntries $currentManifest 'current'
$nextEntries = Get-OwnedEntries $nextManifest 'staged'
$managedEntries = @($currentEntries + $nextEntries | Sort-Object -Unique)
$backupRoot = Join-Path $work 'old'
$backedUp = [Collections.Generic.List[string]]::new()
$placed = [Collections.Generic.List[string]]::new()

$deadline = [DateTime]::UtcNow.AddSeconds(120)
while (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue) {
  if ([DateTime]::UtcNow -ge $deadline) { throw "CedarDSH Desktop process $ParentProcessId did not exit within 120 seconds" }
  Start-Sleep -Milliseconds 250
}

try {
  $currentEntrySet = @{}
  foreach ($entry in $currentEntries) { $currentEntrySet[$entry] = $true }
  foreach ($entry in $nextEntries) {
    $target = Join-Path $root $entry
    if (-not $currentEntrySet.ContainsKey($entry) -and (Test-Path -LiteralPath $target)) {
      throw "update would replace an unowned top-level entry: $entry"
    }
  }

  New-Item -ItemType Directory -Path $backupRoot | Out-Null
  foreach ($entry in $managedEntries) {
    $target = Join-Path $root $entry
    Assert-ChildPath $root $target "current entry '$entry'"
    if (-not (Test-Path -LiteralPath $target)) { continue }
    $backup = Join-Path $backupRoot $entry
    Move-Item -LiteralPath $target -Destination $backup
    $backedUp.Add($entry)
  }

  foreach ($entry in $nextEntries) {
    $source = Join-Path $stagedRoot $entry
    $target = Join-Path $root $entry
    Assert-ChildPath $stagedRoot $source "staged entry '$entry'"
    Assert-ChildPath $root $target "new entry '$entry'"
    if (-not (Test-Path -LiteralPath $source)) { throw "staged entry is missing: $entry" }
    Move-Item -LiteralPath $source -Destination $target
    $placed.Add($entry)
  }

  $requiredUpdatedFiles = @(
    'CedarDSH-Desktop.exe',
    'runtime\node.exe',
    'resources\app\package.json',
    'resources\app\main.js',
    'resources\app\startup-progress.js',
    'resources\app\launch-args.js',
    'resources\app\process-lifecycle.js',
    'resources\app\diagnostics.js',
    'resources\app\deepseek-mark.svg',
    'resources\app\update.js',
    'resources\app\update-helper.ps1',
    'resources\app\update-install.js',
    'resources\app\cedardsh.patch.yml',
    'app\node_modules\@deepseek-ai\dsh\lib\bin.js',
    'app\node_modules\@cedardsh\desktop-update\package.json',
    'app\node_modules\@cedardsh\desktop-update\lib\index.js',
    'app\node_modules\@cedardsh\desktop-update\lib\client.js'
  )
  foreach ($relativePath in $requiredUpdatedFiles) {
    $requiredPath = Join-Path $root $relativePath
    Assert-ChildPath $root $requiredPath "updated file '$relativePath'"
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "updated package is missing required file: $relativePath"
    }
  }

  $newExe = Join-Path $root 'CedarDSH-Desktop.exe'
  Write-UpdateLog $root "updated CedarDSH Desktop $($currentManifest.portableVersion) -> $($nextManifest.portableVersion); preserved dsh-home and workspace"
  if (-not $SkipRestart) { Start-Process -FilePath $newExe -WorkingDirectory $root }
  try { Remove-UpdatePath $work } catch { Write-UpdateLog $root "update cleanup deferred: $($_.Exception.Message)" }
  exit 0
} catch {
  $installError = $_.Exception.Message
  $rollbackErrors = [Collections.Generic.List[string]]::new()

  foreach ($entry in @($placed)) {
    $target = Join-Path $root $entry
    try {
      Assert-ChildPath $root $target "rollback entry '$entry'"
      Remove-UpdatePath $target
    } catch {
      $rollbackErrors.Add("remove ${entry}: $($_.Exception.Message)")
    }
  }
  foreach ($entry in @($backedUp)) {
    $backup = Join-Path $backupRoot $entry
    $target = Join-Path $root $entry
    try {
      if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $target }
    } catch {
      $rollbackErrors.Add("restore ${entry}: $($_.Exception.Message)")
    }
  }

  $rollbackDetail = if ($rollbackErrors.Count -eq 0) { 'rollback completed' } else { "rollback errors: $($rollbackErrors -join '; ')" }
  Write-UpdateLog $root "update failed: $installError; $rollbackDetail"
  $oldExe = Join-Path $root 'CedarDSH-Desktop.exe'
  if (-not $SkipRestart -and $rollbackErrors.Count -eq 0 -and (Test-Path -LiteralPath $oldExe -PathType Leaf)) {
    Start-Process -FilePath $oldExe -WorkingDirectory $root
  }
  exit 1
}
