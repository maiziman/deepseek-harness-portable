param(
  [Parameter(Mandatory = $true)]
  [string]$HelperPath,
  [Parameter(Mandatory = $true)]
  [string]$RootPath,
  [Parameter(Mandatory = $true)]
  [string]$StagedRootPath,
  [Parameter(Mandatory = $true)]
  [string]$WorkPath,
  [Parameter(Mandatory = $true)]
  [int]$ParentProcessId,
  [Parameter(Mandatory = $true)]
  [string]$ReadyPath,
  [Parameter(Mandatory = $true)]
  [string]$ErrorPath,
  [switch]$SkipRestart
)

$ErrorActionPreference = 'Stop'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = @(
  '-NoLogo',
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  $HelperPath,
  '-Mode',
  'Install',
  '-RootPath',
  $RootPath,
  '-StagedRootPath',
  $StagedRootPath,
  '-WorkPath',
  $WorkPath,
  '-ParentProcessId',
  [string]$ParentProcessId,
  '-ReadyPath',
  $ReadyPath,
  '-ErrorPath',
  $ErrorPath
)
if ($SkipRestart) { $arguments += '-SkipRestart' }

$quotedArguments = @($arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' })
$commandLine = '"' + $powershell + '" ' + ($quotedArguments -join ' ')
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine }
if ($created.ReturnValue -ne 0) { throw "could not create independent updater process: $($created.ReturnValue)" }

$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $ReadyPath -PathType Leaf)) {
  $updater = Get-Process -Id $created.ProcessId -ErrorAction SilentlyContinue
  if (-not $updater) {
    $detail = if (Test-Path -LiteralPath $ErrorPath -PathType Leaf) {
      Get-Content -Raw -LiteralPath $ErrorPath
    } else {
      'independent updater exited before accepting the handoff'
    }
    throw $detail
  }
  if ([DateTime]::UtcNow -ge $deadline) {
    Stop-Process -InputObject $updater -Force -ErrorAction SilentlyContinue
    Wait-Process -InputObject $updater -ErrorAction SilentlyContinue
    throw 'independent updater did not accept the handoff within 30 seconds'
  }
  Start-Sleep -Milliseconds 50
}
