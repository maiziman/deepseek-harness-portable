# Compatibility probe for the portable package: deterministic pass/fail with
# one command, runnable on any Windows machine, in Windows Sandbox, and on
# GitHub Actions windows runners.
#
# What it verifies (the same checks a real user's first run performs):
#   1. the ZIP extracts to a complete tree (exe, manifest, runtime, app)
#   2. the bundled node.exe is the manifest version
#   3. the packaged app boots: server starts, URL announced, UI renders,
#      screenshot captured, exit code 0
#   4. first-run profile auto-initialization happens
#
# Usage:
#   .\verify-package.ps1                       # newest zip in dist\
#   .\verify-package.ps1 -ZipPath X.zip        # specific package
#   .\verify-package.ps1 -Keep                 # keep the extracted tree
[CmdletBinding()]
param(
  [string]$ZipPath = '',
  [string]$WorkDir = '',
  [switch]$Keep
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if (-not $ZipPath) {
  $candidates = Get-ChildItem (Join-Path $root 'dist\*.zip') -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
  if ($candidates) { $ZipPath = $candidates[0].FullName }
}
if (-not $ZipPath -or -not (Test-Path $ZipPath)) { throw 'no ZIP found (pass -ZipPath or build first)' }
if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ('dsh-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
Write-Output "=== verify: $ZipPath"

# ── 1. extract ───────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
if (Get-Command tar -ErrorAction SilentlyContinue) { tar -xf $ZipPath -C $WorkDir }
else { Expand-Archive -Path $ZipPath -DestinationPath $WorkDir -Force }
$pkgRoot = Join-Path $WorkDir 'DeepSeek-Harness'
$exe = Join-Path $pkgRoot 'DeepSeek-Harness.exe'
if (-not (Test-Path $exe)) { throw "extraction incomplete: $exe missing" }
Write-Output ('[1/4] extraction OK: {0} files' -f (Get-ChildItem $pkgRoot -Recurse -File).Count)

# ── 2. manifest + node runtime ───────────────────────────────────────────────
$manifestPath = Join-Path $pkgRoot 'manifest.json'
if (-not (Test-Path $manifestPath)) { throw 'manifest.json missing' }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$nodeVer = & (Join-Path $pkgRoot 'runtime\node.exe') --version
if ($nodeVer.Trim() -ne $manifest.nodeVersion) { throw "node version mismatch: $($nodeVer.Trim()) != $($manifest.nodeVersion)" }
Write-Output ('[2/4] manifest OK: dsh {0} / node {1} / electron {2}' -f $manifest.dshVersion, $manifest.nodeVersion, $manifest.electronVersion)

# ── 3. smoke: boot the app, capture the UI ───────────────────────────────────
$smoke = Join-Path $WorkDir 'smoke.png'
$saved = @{
  DSH_SMOKE = $env:DSH_SMOKE
  DSH_SMOKE_OUT = $env:DSH_SMOKE_OUT
  DSH_SMOKE_DELAY_MS = $env:DSH_SMOKE_DELAY_MS
}
try {
  $env:DSH_SMOKE = '1'
  $env:DSH_SMOKE_OUT = $smoke
  $env:DSH_SMOKE_DELAY_MS = '4000'
  $proc = Start-Process -FilePath $exe -WorkingDirectory $pkgRoot -PassThru
  if (-not $proc.WaitForExit(150000)) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw 'smoke timed out after 150s'
  }
  if ($proc.ExitCode -ne 0) { throw "smoke exited $($proc.ExitCode); see $pkgRoot\dsh-home\logs\server.log" }
  $img = Get-Item $smoke
  if ($img.Length -lt 10240) { throw "screenshot suspiciously small: $($img.Length) bytes" }
  Write-Output ('[3/4] smoke OK: exit 0, UI screenshot {0} KB' -f [math]::Round($img.Length / 1KB))
} finally {
  $env:DSH_SMOKE = $saved.DSH_SMOKE
  $env:DSH_SMOKE_OUT = $saved.DSH_SMOKE_OUT
  $env:DSH_SMOKE_DELAY_MS = $saved.DSH_SMOKE_DELAY_MS
}

# ── 4. first-run behavior: URL announced + profile auto-init ─────────────────
$log = Get-Content (Join-Path $pkgRoot 'dsh-home\logs\server.log') -Raw
if ($log -notmatch 'dsh web: http://') { throw 'server never announced its URL' }
if (-not (Test-Path (Join-Path $pkgRoot 'dsh-home\profiles\web'))) { throw 'web profile was not initialized' }
if (-not (Test-Path (Join-Path $pkgRoot 'dsh-home\profiles\node_modules\@deepseek-ai\dsh'))) { throw 'installation fallback not prepared' }
Write-Output '[4/4] first-run OK: server URL announced, web profile initialized'

Write-Output '=== VERIFY PASSED ==='
if (-not $Keep) { Remove-Item -Recurse -Force $WorkDir }
