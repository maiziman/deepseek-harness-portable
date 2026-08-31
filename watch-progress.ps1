# Progress watcher: appends one real-time status line every 20 seconds to
# .build-progress.log while the portable build runs. Stops when the build
# finishes. Watch it in another terminal with:
#   Get-Content D:\Harness-Deepseek\portable-desktop\.build-progress.log -Wait -Tail 10
$ErrorActionPreference = 'SilentlyContinue'
$root = $PSScriptRoot
$outLog = Join-Path $root '.build-progress.log'
$bootstrap = Join-Path $root '.build-run.log'
$app = Join-Path $root '.build\app'
$profile = Join-Path $root '.build\profile'
$dist = Join-Path $root 'dist'

function Get-AppStats {
  $files = Get-ChildItem $app -Recurse -File
  $sum = ($files | Measure-Object Length -Sum).Sum
  [pscustomobject]@{
    Files = $files.Count
    MB = [math]::Round($sum / 1MB, 1)
  }
}

Add-Content $outLog "watcher started $(Get-Date -Format HH:mm:ss)"
while ($true) {
  $stats = Get-AppStats
  $npmLog = Get-ChildItem "$env:LOCALAPPDATA\npm-cache\_logs" -Filter *.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $npmLogTime = if ($npmLog) { $npmLog.LastWriteTime.ToString('HH:mm:ss') } else { '-' }
  $stage = 'installing dsh deps'
  if (Test-Path (Join-Path $profile 'CedarDSH-Desktop\CedarDSH-Desktop.exe')) { $stage = 'assembling / zipping' }
  elseif (Test-Path (Join-Path $profile 'CedarDSH Desktop-win32-x64\CedarDSH-Desktop.exe')) { $stage = 'electron packager' }
  elseif (Test-Path (Join-Path $env:TEMP 'dsh-portable-build\tools\node_modules\electron')) { $stage = 'loading electron tools' }
  elseif ($stats.Files -gt 0) { $stage = 'extracting packages' }
  $line = "{0}  files={1}  size={2} MB  npmLog={3}  stage={4}" -f (Get-Date -Format HH:mm:ss), $stats.Files, $stats.MB, $npmLogTime, $stage
  Add-Content $outLog $line
  Write-Output $line
  if (Select-String -Quiet -Path $bootstrap -Pattern '=== DONE') {
    Add-Content $outLog "build finished $(Get-Date -Format HH:mm:ss)"
    Write-Output 'build finished'
    break
  }
  Start-Sleep -Seconds 20
}
