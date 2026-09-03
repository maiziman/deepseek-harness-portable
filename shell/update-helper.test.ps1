$ErrorActionPreference = 'Stop'

$helper = Join-Path $PSScriptRoot 'update-helper.ps1'
$launcher = Join-Path $PSScriptRoot 'update-launcher.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "cedardsh update helper test $([guid]::NewGuid().ToString('N'))"

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
      'resources\app\update-launcher.ps1',
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
  $spacedScriptRoot = Join-Path $testRoot 'update scripts'
  New-Item -ItemType Directory -Path $spacedScriptRoot | Out-Null
  $spacedHelper = Join-Path $spacedScriptRoot 'update helper.ps1'
  $spacedLauncher = Join-Path $spacedScriptRoot 'update launcher.ps1'
  Copy-Item -LiteralPath $helper -Destination $spacedHelper
  Copy-Item -LiteralPath $launcher -Destination $spacedLauncher
  $ownedCurrent = @('app', 'runtime', 'resources', 'CedarDSH-Desktop.exe', 'manifest.json', 'obsolete.dll')
  $ownedNext = @('app', 'runtime', 'resources', 'CedarDSH-Desktop.exe', 'manifest.json')

  $archiveSource = Join-Path $testRoot 'archive-source\CedarDSH-Desktop'
  $archivePath = Join-Path $testRoot 'update.zip'
  $extractDestination = Join-Path $testRoot 'archive-extract'
  New-Item -ItemType Directory -Force -Path $archiveSource | Out-Null
  Set-Content -LiteralPath (Join-Path $archiveSource 'marker.txt') -Value 'archive' -NoNewline
  Compress-Archive -LiteralPath $archiveSource -DestinationPath $archivePath
  $extractModule = Join-Path $PSScriptRoot 'update-install.js'
  $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
  & node -e "const {extractArchive}=require(process.argv[1]);extractArchive(process.argv[2],process.argv[3],{tarPath:process.argv[4],onProgress:()=>{}}).catch(error=>{console.error(error);process.exitCode=1})" `
    $extractModule $archivePath $extractDestination $tar
  if ($LASTEXITCODE -ne 0) { throw "extract case exited $LASTEXITCODE" }
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

  $parentScript = Join-Path $testRoot 'parent.ps1'
  Set-Content -LiteralPath $parentScript -Value 'Start-Sleep -Seconds 5'
  $quotedParentScript = '"' + $parentScript + '"'
  $parent = Start-Process -FilePath $powershell `
    -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $quotedParentScript) `
    -WindowStyle Hidden -PassThru
  & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $spacedLauncher `
    -HelperPath $spacedHelper -RootPath $successRoot -StagedRootPath $successStage -WorkPath $successWork `
    -ParentProcessId $parent.Id -ReadyPath (Join-Path $successWork 'handoff.ready') `
    -ErrorPath (Join-Path $successWork 'handoff.error') -SkipRestart
  if ($LASTEXITCODE -ne 0) { throw "successful launcher case exited $LASTEXITCODE" }
  Assert-Equal (Get-Content -Raw (Join-Path $successRoot 'app\marker.txt')) 'old' 'update started before the parent exited'
  $parent.WaitForExit()
  $installDeadline = [DateTime]::UtcNow.AddSeconds(10)
  $successMarker = Join-Path $successRoot 'app\marker.txt'
  while (-not (Test-Path -LiteralPath $successMarker) `
      -or (Get-Content -Raw -LiteralPath $successMarker) -cne 'new' `
      -or (Test-Path -LiteralPath $successWork)) {
    if ([DateTime]::UtcNow -ge $installDeadline) { throw 'independent updater did not replace the package after the parent exited' }
    Start-Sleep -Milliseconds 100
  }
  Assert-Equal (Get-Content -Raw (Join-Path $successRoot 'app\marker.txt')) 'new' 'app was not updated'
  Assert-Equal (Get-Content -Raw (Join-Path $successRoot 'dsh-home\history.txt')) 'history' 'history changed'
  Assert-Equal (Get-Content -Raw (Join-Path $successRoot 'workspace\user.txt')) 'workspace' 'workspace changed'
  Assert-Equal (Get-Content -Raw (Join-Path $successRoot 'my-tool.txt')) 'unknown' 'unknown file changed'
  Assert-Equal (Get-Content -Raw (Join-Path $successSentinelRoot 'sentinel.txt')) 'keep' 'successful cleanup entered a junction target'
  if (Test-Path -LiteralPath $successWork) { throw 'successful update work directory was not removed' }
  if (Test-Path -LiteralPath (Join-Path $successRoot 'obsolete.dll')) { throw 'obsolete owned file was not removed' }

  # A handoff rejected before readiness returns the helper's exact error.
  $preflightRoot = Join-Path $testRoot 'preflight\CedarDSH-Desktop'
  $preflightWork = Join-Path $preflightRoot '.cedardsh-update\1.3.0\run-preflight'
  $preflightStage = Join-Path $preflightWork 'extract\CedarDSH-Desktop'
  New-Item -ItemType Directory -Force -Path $preflightRoot, $preflightStage | Out-Null
  Write-Package $preflightRoot '1.2.2' $ownedCurrent 'old'
  $ErrorActionPreference = 'Continue'
  $preflightOutput = & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $spacedLauncher `
    -HelperPath $spacedHelper -RootPath $preflightRoot -StagedRootPath $preflightStage -WorkPath $preflightWork `
    -ParentProcessId $PID -ReadyPath (Join-Path $preflightWork 'handoff.ready') `
    -ErrorPath (Join-Path $preflightWork 'handoff.error') -SkipRestart 2>&1
  $preflightExitCode = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($preflightExitCode -eq 0) { throw 'preflight failure unexpectedly succeeded' }
  if (($preflightOutput | Out-String) -notmatch 'staged manifest is missing') {
    throw "preflight failure hid the helper error: $($preflightOutput | Out-String)"
  }
  Assert-Equal (Get-Content -Raw (Join-Path $preflightRoot 'app\marker.txt')) 'old' 'program changed during preflight failure'

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
    -ParentProcessId 2000000000 -ReadyPath (Join-Path $rollbackWork 'handoff.ready') `
    -ErrorPath (Join-Path $rollbackWork 'handoff.error') -SkipRestart
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
    -ParentProcessId 2000000000 -ReadyPath (Join-Path $collisionWork 'handoff.ready') `
    -ErrorPath (Join-Path $collisionWork 'handoff.error') -SkipRestart
  if ($LASTEXITCODE -eq 0) { throw 'ownership collision helper case unexpectedly succeeded' }
  Assert-Equal (Get-Content -Raw (Join-Path $collisionRoot 'new-runtime.dll')) 'user file' 'unowned root file changed'
  Assert-Equal (Get-Content -Raw (Join-Path $collisionRoot 'app\marker.txt')) 'old' 'program changed during ownership collision'

  Write-Output 'update helper tests passed'
} finally {
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($resolvedTestRoot).StartsWith('cedardsh update helper test ')) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$global:LASTEXITCODE = 0
