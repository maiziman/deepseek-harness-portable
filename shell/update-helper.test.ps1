$ErrorActionPreference = 'Stop'

$helper = Join-Path $PSScriptRoot 'update-helper.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "cedardsh-update-helper-test-$([guid]::NewGuid().ToString('N'))"

function Write-Package([string]$Root, [string]$Version, [string[]]$Owned, [string]$Marker, [string]$OmitRequiredFile = '') {
  foreach ($directory in @(
      'app\node_modules\@deepseek-ai\dsh\lib',
      'app\node_modules\@cedardsh\desktop-update\lib',
      'resources\app',
      'runtime',
      'dsh-home',
      'workspace'
    )) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $directory) | Out-Null
  }
  Set-Content -LiteralPath (Join-Path $Root 'app\marker.txt') -Value $Marker -NoNewline
  Set-Content -LiteralPath (Join-Path $Root 'resources\marker.txt') -Value $Marker -NoNewline
  Set-Content -LiteralPath (Join-Path $Root 'runtime\marker.txt') -Value $Marker -NoNewline
  foreach ($requiredFile in @(
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
    )) {
    if ($requiredFile -cne $OmitRequiredFile) {
      Set-Content -LiteralPath (Join-Path $Root $requiredFile) -Value $Marker -NoNewline
    }
  }
  if ($Owned -contains 'obsolete.dll') { Set-Content -LiteralPath (Join-Path $Root 'obsolete.dll') -Value $Marker -NoNewline }
  [ordered]@{
    portableVersion = $Version
    dshVersion = $Version
    ownedTopLevelEntries = $Owned
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'manifest.json')
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -cne $Expected) { throw "$Message`: '$Actual' != '$Expected'" }
}

try {
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $ownedCurrent = @('app', 'runtime', 'resources', 'CedarDSH-Desktop.exe', 'manifest.json', 'obsolete.dll')
  $ownedNext = @('app', 'runtime', 'resources', 'CedarDSH-Desktop.exe', 'manifest.json')

  $archiveSource = Join-Path $testRoot 'archive-source\CedarDSH-Desktop'
  $archivePath = Join-Path $testRoot 'update.zip'
  $extractDestination = Join-Path $testRoot 'archive-extract'
  New-Item -ItemType Directory -Force -Path $archiveSource | Out-Null
  Set-Content -LiteralPath (Join-Path $archiveSource 'marker.txt') -Value 'archive' -NoNewline
  Compress-Archive -LiteralPath $archiveSource -DestinationPath $archivePath
  & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper `
    -Mode Extract -ArchivePath $archivePath -DestinationPath $extractDestination
  if ($LASTEXITCODE -ne 0) { throw "extract helper case exited $LASTEXITCODE" }
  Assert-Equal (Get-Content -Raw (Join-Path $extractDestination 'CedarDSH-Desktop\marker.txt')) 'archive' 'archive was not extracted'

  # Successful replacement: program entries change, preserved and unknown files do not.
  $successRoot = Join-Path $testRoot 'success\CedarDSH-Desktop'
  $successWork = Join-Path $successRoot '.cedardsh-update\1.3.0\run-success'
  $successStage = Join-Path $successWork 'extract\CedarDSH-Desktop'
  New-Item -ItemType Directory -Force -Path $successRoot, $successStage | Out-Null
  Write-Package $successRoot '1.2.2' $ownedCurrent 'old'
  Write-Package $successStage '1.3.0' $ownedNext 'new'
  Set-Content -LiteralPath (Join-Path $successRoot 'dsh-home\history.txt') -Value 'history' -NoNewline
  Set-Content -LiteralPath (Join-Path $successRoot 'workspace\user.txt') -Value 'workspace' -NoNewline
  Set-Content -LiteralPath (Join-Path $successRoot 'my-tool.txt') -Value 'unknown' -NoNewline
  $successSentinelRoot = Join-Path $testRoot 'success-external-sentinel'
  New-Item -ItemType Directory -Path $successSentinelRoot | Out-Null
  Set-Content -LiteralPath (Join-Path $successSentinelRoot 'sentinel.txt') -Value 'keep' -NoNewline
  New-Item -ItemType Junction -Path (Join-Path $successRoot 'app\external-link') -Target $successSentinelRoot | Out-Null

  & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper `
    -Mode Install -RootPath $successRoot -StagedRootPath $successStage -WorkPath $successWork `
    -ParentProcessId 2000000000 -SkipRestart
  if ($LASTEXITCODE -ne 0) { throw "successful helper case exited $LASTEXITCODE" }
  Assert-Equal (Get-Content -Raw (Join-Path $successRoot 'app\marker.txt')) 'new' 'app was not updated'
  Assert-Equal (Get-Content -Raw (Join-Path $successRoot 'dsh-home\history.txt')) 'history' 'history changed'
  Assert-Equal (Get-Content -Raw (Join-Path $successRoot 'workspace\user.txt')) 'workspace' 'workspace changed'
  Assert-Equal (Get-Content -Raw (Join-Path $successRoot 'my-tool.txt')) 'unknown' 'unknown file changed'
  Assert-Equal (Get-Content -Raw (Join-Path $successSentinelRoot 'sentinel.txt')) 'keep' 'successful cleanup entered a junction target'
  if (Test-Path -LiteralPath $successWork) { throw 'successful update work directory was not removed' }
  if (Test-Path -LiteralPath (Join-Path $successRoot 'obsolete.dll')) { throw 'obsolete owned file was not removed' }

  # Failed replacement: a missing required file forces the old program back in place.
  $rollbackRoot = Join-Path $testRoot 'rollback\CedarDSH-Desktop'
  $rollbackWork = Join-Path $rollbackRoot '.cedardsh-update\1.3.0\run-rollback'
  $rollbackStage = Join-Path $rollbackWork 'extract\CedarDSH-Desktop'
  New-Item -ItemType Directory -Force -Path $rollbackRoot, $rollbackStage | Out-Null
  Write-Package $rollbackRoot '1.2.2' $ownedCurrent 'old'
  Write-Package $rollbackStage '1.3.0' $ownedNext 'new' -OmitRequiredFile 'runtime\node.exe'
  Set-Content -LiteralPath (Join-Path $rollbackRoot 'dsh-home\history.txt') -Value 'history' -NoNewline
  Set-Content -LiteralPath (Join-Path $rollbackRoot 'workspace\user.txt') -Value 'workspace' -NoNewline
  $rollbackSentinelRoot = Join-Path $testRoot 'rollback-external-sentinel'
  New-Item -ItemType Directory -Path $rollbackSentinelRoot | Out-Null
  Set-Content -LiteralPath (Join-Path $rollbackSentinelRoot 'sentinel.txt') -Value 'keep' -NoNewline
  New-Item -ItemType Junction -Path (Join-Path $rollbackStage 'app\external-link') -Target $rollbackSentinelRoot | Out-Null

  & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper `
    -Mode Install -RootPath $rollbackRoot -StagedRootPath $rollbackStage -WorkPath $rollbackWork `
    -ParentProcessId 2000000000 -SkipRestart
  if ($LASTEXITCODE -eq 0) { throw 'rollback helper case unexpectedly succeeded' }
  Assert-Equal (Get-Content -Raw (Join-Path $rollbackRoot 'app\marker.txt')) 'old' 'old app was not restored'
  Assert-Equal (Get-Content -Raw (Join-Path $rollbackRoot 'runtime\marker.txt')) 'old' 'old runtime was not restored'
  Assert-Equal (Get-Content -Raw (Join-Path $rollbackRoot 'dsh-home\history.txt')) 'history' 'history changed during rollback'
  Assert-Equal (Get-Content -Raw (Join-Path $rollbackRoot 'workspace\user.txt')) 'workspace' 'workspace changed during rollback'
  Assert-Equal (Get-Content -Raw (Join-Path $rollbackSentinelRoot 'sentinel.txt')) 'keep' 'rollback entered a junction target'

  # A newly owned name must not claim an existing user file at the package root.
  $collisionRoot = Join-Path $testRoot 'collision\CedarDSH-Desktop'
  $collisionWork = Join-Path $collisionRoot '.cedardsh-update\1.3.0\run-collision'
  $collisionStage = Join-Path $collisionWork 'extract\CedarDSH-Desktop'
  New-Item -ItemType Directory -Force -Path $collisionRoot, $collisionStage | Out-Null
  Write-Package $collisionRoot '1.2.2' $ownedCurrent 'old'
  $collisionNextOwned = @($ownedNext + 'new-runtime.dll')
  Write-Package $collisionStage '1.3.0' $collisionNextOwned 'new'
  Set-Content -LiteralPath (Join-Path $collisionStage 'new-runtime.dll') -Value 'new program file' -NoNewline
  Set-Content -LiteralPath (Join-Path $collisionRoot 'new-runtime.dll') -Value 'user file' -NoNewline

  & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper `
    -Mode Install -RootPath $collisionRoot -StagedRootPath $collisionStage -WorkPath $collisionWork `
    -ParentProcessId 2000000000 -SkipRestart
  if ($LASTEXITCODE -eq 0) { throw 'ownership collision helper case unexpectedly succeeded' }
  Assert-Equal (Get-Content -Raw (Join-Path $collisionRoot 'new-runtime.dll')) 'user file' 'unowned root file changed'
  Assert-Equal (Get-Content -Raw (Join-Path $collisionRoot 'app\marker.txt')) 'old' 'program changed during ownership collision'

  Write-Output 'update helper tests passed'
} finally {
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($resolvedTestRoot).StartsWith('cedardsh-update-helper-test-')) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$global:LASTEXITCODE = 0
