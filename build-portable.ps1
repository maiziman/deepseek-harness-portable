# Build the DeepSeek Harness portable desktop package for Windows x64.
#
# Produces: dist\DeepSeek-Harness-win64-v<dsh-version>.zip (+ SHA256SUMS.txt)
#
# The package layout (zip root: DeepSeek-Harness\):
#   DeepSeek-Harness.exe   Electron shell; double-click entry point
#   resources\app\...      shell sources (main.js)
#   runtime\               official Node.js win-x64 with npm
#   app\node_modules\      production install of @deepseek-ai/dsh and deps
#   dsh-home\  workspace\  data dirs (DSH_HOME points here; all data stays in-package)
#   README.txt  dsh.cmd  manifest.json
[CmdletBinding()]
param(
  [string]$DshVersion = '',
  [string]$NodeVersion = 'v24.19.0',
  [string]$ElectronVersion = '44.0.0',
  [string]$ElectronMirror = 'npmmirror',
  [switch]$SkipSmoke,
  [switch]$ForceDownloadNode
)
$ErrorActionPreference = 'Stop'

$psRoot = $PSScriptRoot
$repoRoot = Split-Path $psRoot -Parent
$build = Join-Path $psRoot '.build'
$dist = Join-Path $psRoot 'dist'
$profile = Join-Path $build 'profile'
$staging = Join-Path $build 'shell-stage'
# The dependency installs run in a scratch dir OUTSIDE this repository: the
# repo root is itself a pnpm workspace (pnpm-workspace.yaml), and installing a
# package inside it with --prod trips the workspace include-deps conflict
# (ERR_PNPM_INCLUDED_DEPS_CONFLICT) against the root node_modules.
$scratch = Join-Path $env:TEMP 'dsh-portable-build'
$tools = Join-Path $scratch 'tools'

# pnpm is used instead of npm for all installs: the dsh dependency graph is a
# few hundred packages and npm's reify planning stalls on it for minutes with
# no disk writes, while pnpm resolves and extracts it in seconds. The tar
# extraction drops pnpm into the runtime copy, so nothing depends on corepack
# or a global install.
function Install-Pnpm {
  $target = Join-Path $build 'runtime\node_modules\pnpm'
  if (Test-Path (Join-Path $target 'bin\pnpm.cjs')) { return }
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  # Cache outside .build so a failed build does not re-download the tarball.
  $cacheDir = Join-Path $psRoot '.cache'
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $tgz = Join-Path $cacheDir 'pnpm-11.7.0.tgz'
  if (-not (Test-Path $tgz)) {
    $sources = @(
      'https://registry.npmmirror.com/pnpm/-/pnpm-11.7.0.tgz',
      'https://registry.npmjs.org/pnpm/-/pnpm-11.7.0.tgz'
    )
    $ok = $false
    foreach ($src in $sources) {
      for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        try {
          Invoke-WebRequest -Uri $src -OutFile $tgz -TimeoutSec 120
          $ok = $true
        } catch {
          Write-Warning "pnpm download failed ($src, attempt $attempt): $($_.Exception.Message)"
          Start-Sleep -Seconds 2
        }
      }
      if ($ok) { break }
    }
    if (-not $ok) { throw 'pnpm tarball download failed from all sources' }
  }
  tar -xzf $tgz -C $target --strip-components=1
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $target 'bin\pnpm.cjs'))) {
    throw 'pnpm tarball extraction failed'
  }
}

function Install-Target([string]$target, [string[]]$pkgs, [switch]$ProdOnly) {
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  # pnpm 10+/11 ignores the package.json "pnpm" field; the onlyBuiltDependencies
  # allowlist (postinstall scripts) lives in pnpm-workspace.yaml, and creating
  # one here also makes this dir its own workspace root.
  $wsYaml = Join-Path $target 'pnpm-workspace.yaml'
  if (-not (Test-Path $wsYaml)) {
    if ($ProdOnly) {
      # Production deps with postinstall scripts: koffi (native FFI binding),
      # node-pty (native terminal), the local subprocess provider, and the
      # Google GenAI / protobufjs helpers. Without these scripts the native
      # prebuilds are not wired up.
      $built = @(
        "'@deepseek-ai/dsh-subprocess-local'",
        "'@google/genai'",
        "'koffi'",
        "'node-pty'",
        "'protobufjs'"
      )
    } else {
      $built = @("'electron'")
    }
    "onlyBuiltDependencies:`n" + (($built | ForEach-Object { "  - $_" }) -join "`n") | Set-Content $wsYaml
  }
  $argsList = @('--dir', $target, 'add', '--node-linker=hoisted', '--reporter=append-only')
  if ($ProdOnly) { $argsList += '--prod' }
  $pnpmCjs = Join-Path $build 'runtime\node_modules\pnpm\bin\pnpm.cjs'
  & (Join-Path $build 'runtime\node.exe') $pnpmCjs @argsList @pkgs
  if ($LASTEXITCODE -ne 0) { throw "pnpm install failed in $target (exit $LASTEXITCODE)" }
}

# ── 0. resolve versions ──────────────────────────────────────────────────────
if (-not $DshVersion) {
  $meta = Invoke-RestMethod -Uri 'https://registry.npmjs.org/@deepseek-ai/dsh'
  $DshVersion = [string]$meta.'dist-tags'.latest
}
if ($DshVersion -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { throw "unexpected version format: $DshVersion" }
if ($NodeVersion -notmatch '^v?\d+\.\d+\.\d+$') { throw "unexpected Node version: $NodeVersion" }
if (-not $NodeVersion.StartsWith('v')) { $NodeVersion = 'v' + $NodeVersion }

Write-Output "=== target: dsh $DshVersion, node $NodeVersion, electron $ElectronVersion ==="

# Electron binary source: npmmirror (default, for CN networks), github
# (official, for CI runners), or any custom @electron/get mirror URL.
if ($ElectronMirror -eq 'npmmirror') {
  $env:ELECTRON_MIRROR = 'https://npmmirror.com/mirrors/electron/'
  $env:ELECTRON_CUSTOM_DIR = '{{ version }}'
} elseif ($ElectronMirror -eq 'github') {
  Remove-Item Env:ELECTRON_MIRROR -ErrorAction SilentlyContinue
  Remove-Item Env:ELECTRON_CUSTOM_DIR -ErrorAction SilentlyContinue
} elseif ($ElectronMirror -ne '') {
  $env:ELECTRON_MIRROR = $ElectronMirror
  $env:ELECTRON_CUSTOM_DIR = '{{ version }}'
}

# ── 1. clean and prepare ─────────────────────────────────────────────────────
if (Test-Path $build) { Remove-Item -Recurse -Force $build }
if (Test-Path $scratch) { Remove-Item -Recurse -Force $scratch }
New-Item -ItemType Directory -Force -Path $build, $dist, $tools | Out-Null

# ── 2. Node runtime ──────────────────────────────────────────────────────────
$runtimeSrc = Join-Path $repoRoot ".runtime\node-$NodeVersion-win-x64"
if ((Test-Path (Join-Path $runtimeSrc 'node.exe')) -and -not $ForceDownloadNode) {
  Write-Output "=== runtime: reusing local $runtimeSrc ==="
  Copy-Item -Recurse -Force $runtimeSrc (Join-Path $build 'runtime')
} else {
  Write-Output "=== runtime: downloading Node from nodejs.org ==="
  $zipFile = Join-Path $build "node-$NodeVersion-win-x64.zip"
  Invoke-WebRequest -Uri "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-x64.zip" -OutFile $zipFile
  $shasums = Invoke-WebRequest -Uri "https://nodejs.org/dist/$NodeVersion/SHASUMS256.txt" | Select-Object -ExpandProperty Content
  $expected = ($shasums -split "`n" | Where-Object { $_ -match "node-$NodeVersion-win-x64.zip$" } | Select-Object -First 1).Split(' ')[0]
  if (-not $expected) { throw 'could not find the expected SHA256 in SHASUMS256.txt' }
  $actual = (Get-FileHash $zipFile -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $expected.ToLower()) { throw "Node zip SHA256 mismatch: $actual != $expected" }
  tar -xf $zipFile -C $build
  if ($LASTEXITCODE -ne 0) { throw 'tar extraction of the Node zip failed' }
  Move-Item (Join-Path $build "node-$NodeVersion-win-x64") (Join-Path $build 'runtime')
}
$nodeVer = & (Join-Path $build 'runtime\node.exe') --version
if ($nodeVer.Trim() -ne $NodeVersion) { throw "bundled node reports $nodeVer, expected $NodeVersion" }

# ── 3. production install of @deepseek-ai/dsh ────────────────────────────────
# Installed into the scratch dir (outside the pnpm workspace), then copied into
# the build tree. node-linker=hoisted yields a flat npm-like node_modules, so
# the packaged tree needs no symlinks (which Windows zip extraction breaks).
$scratchApp = Join-Path $scratch 'app'
Write-Output "=== installing @deepseek-ai/dsh@$DshVersion (production deps, pnpm) ==="
Install-Pnpm
Install-Target $scratchApp -ProdOnly @("@deepseek-ai/dsh@$DshVersion")
$app = Join-Path $build 'app'
Copy-Item -Recurse -Force $scratchApp $app
$dshBin = Join-Path $app 'node_modules\@deepseek-ai\dsh\lib\bin.js'
if (-not (Test-Path $dshBin)) { throw "dsh bin missing after install: $dshBin" }
$dshPkg = Get-Content (Join-Path $app 'node_modules\@deepseek-ai\dsh\package.json') | ConvertFrom-Json
if ($dshPkg.version -ne $DshVersion) { throw "installed dsh version $($dshPkg.version) != $DshVersion" }

# ── 4. Electron tools (build-only) ───────────────────────────────────────────
Write-Output '=== installing electron 44.0.0 + @electron/packager (build-only, pnpm) ==='
Install-Target $tools @("electron@$ElectronVersion", '@electron/packager@20.3.0')

# Electron 44's npm package has no postinstall lifecycle; the binary lands
# through its install-electron bin (node install.js). Run it explicitly.
$electronDir = Join-Path $tools 'node_modules\electron'
if (-not (Test-Path (Join-Path $electronDir 'dist\electron.exe'))) {
  Write-Output '=== electron: downloading binary via install.js ==='
  & (Join-Path $build 'runtime\node.exe') (Join-Path $electronDir 'install.js')
  if ($LASTEXITCODE -ne 0) { throw "electron install.js failed (exit $LASTEXITCODE)" }
}
if (-not (Test-Path (Join-Path $electronDir 'dist\electron.exe'))) { throw 'electron binary missing after install.js' }
$electronZipName = "electron-v$ElectronVersion-win32-x64.zip"
$electronCacheRoot = if ($env:ELECTRON_CACHE) { $env:ELECTRON_CACHE } else { Join-Path $env:LOCALAPPDATA 'electron\Cache' }
$electronZip = Get-ChildItem $electronCacheRoot -Recurse -File -Filter $electronZipName -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $electronZip) { throw "Electron cache archive missing after install.js: $electronZipName" }

# ── 5. stage the shell app and run the packager ──────────────────────────────
$stagingShell = Join-Path $staging 'app'
New-Item -ItemType Directory -Force -Path $stagingShell | Out-Null
Copy-Item (Join-Path $psRoot 'shell\package.json') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\main.js') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\update.js') $stagingShell
Copy-Item (Join-Path $psRoot 'shell\icon.ico') $stagingShell -ErrorAction Stop

Write-Output '=== electron-packager ==='
$packagerCli = @(
  (Join-Path $tools 'node_modules\@electron\packager\bin\electron-packager.mjs'),
  (Join-Path $tools 'node_modules\@electron\packager\bin\electron-packager.js'),
  (Join-Path $tools 'node_modules\@electron\packager\cli.js')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $packagerCli) { throw '@electron/packager bin not found under shell-tools' }
& (Join-Path $build 'runtime\node.exe') $packagerCli $stagingShell 'DshDesktop' `
  --platform=win32 --arch=x64 --out=$profile --overwrite `
  --icon=(Join-Path $stagingShell 'icon.ico') `
  --electron-version=$ElectronVersion --electron-zip-dir=$($electronZip.DirectoryName) `
  --app-version=$DshVersion --no-prune
if ($LASTEXITCODE -ne 0) { throw "electron-packager failed (exit $LASTEXITCODE)" }
$packed = Join-Path $profile 'DshDesktop-win32-x64'
if (-not (Test-Path $packed)) { throw "packager output missing: $packed" }

# ── 6. assemble the portable tree ────────────────────────────────────────────
$pkg = Join-Path $profile 'DeepSeek-Harness'
Rename-Item $packed $pkg
$exe = Join-Path $pkg 'DshDesktop.exe'
if (-not (Test-Path $exe)) { throw "packaged exe missing: $exe" }
Rename-Item $exe (Join-Path $pkg 'DeepSeek-Harness.exe')

Copy-Item -Recurse -Force (Join-Path $build 'runtime') (Join-Path $pkg 'runtime')
Copy-Item -Recurse -Force $app (Join-Path $pkg 'app')
New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'dsh-home'), (Join-Path $pkg 'workspace') | Out-Null
$readme = Get-Content (Join-Path $psRoot 'README.txt') -Raw
$readme = [regex]::Replace($readme, '(?m)^版本：.*$', "版本：dsh $DshVersion / Node $NodeVersion / Electron $ElectronVersion")
Set-Content (Join-Path $pkg 'README.txt') -Value $readme -Encoding utf8 -NoNewline
Copy-Item (Join-Path $psRoot 'dsh.cmd') (Join-Path $pkg 'dsh.cmd')

$manifest = [ordered]@{
  name = 'DeepSeek Harness portable desktop'
  platform = 'win32'; arch = 'x64'
  dshVersion = $DshVersion
  nodeVersion = $NodeVersion
  electronVersion = $ElectronVersion
  updateFeed = 'https://github.com/maiziman/deepseek-harness-portable/releases'
  builtAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  runtimeSource = if ((Test-Path (Join-Path $runtimeSrc 'node.exe')) -and -not $ForceDownloadNode) { 'local-reuse' } else { 'https://nodejs.org/dist/' }
  nodeExeSha256 = (Get-FileHash (Join-Path $pkg 'runtime\node.exe') -Algorithm SHA256).Hash.ToLower()
  shellExeSha256 = (Get-FileHash (Join-Path $pkg 'DeepSeek-Harness.exe') -Algorithm SHA256).Hash.ToLower()
}
$manifest | ConvertTo-Json | Set-Content (Join-Path $pkg 'manifest.json')

# ── 7. smoke test: boot the UI headless and capture a screenshot ─────────────
if (-not $SkipSmoke) {
  Write-Output '=== smoke: launching DeepSeek-Harness.exe ==='
  $smokeOut = Join-Path $build 'smoke.png'
  $envOld = @{ DSH_SMOKE = $env:DSH_SMOKE; DSH_SMOKE_OUT = $env:DSH_SMOKE_OUT }
  try {
    $env:DSH_SMOKE = '1'
    $env:DSH_SMOKE_OUT = $smokeOut
    $proc = Start-Process -FilePath (Join-Path $pkg 'DeepSeek-Harness.exe') -WorkingDirectory $pkg -PassThru
    if (-not $proc.WaitForExit(150000)) {
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      throw 'smoke test timed out after 150s'
    }
    if ($proc.ExitCode -ne 0) {
      throw "smoke test failed (exit $($proc.ExitCode)); see $pkg\dsh-home\logs\server.log"
    }
    if (-not (Test-Path $smokeOut)) { throw 'smoke test passed but no screenshot was written' }
    Write-Output "smoke OK: $smokeOut ($((Get-Item $smokeOut).Length) bytes)"
  } finally {
    $env:DSH_SMOKE = $envOld.DSH_SMOKE
    $env:DSH_SMOKE_OUT = $envOld.DSH_SMOKE_OUT
  }
} else {
  Write-Output '=== smoke skipped ==='
}

# The smoke test auto-initialized dsh-home (profiles/node_modules junctions
# plus logs). Ship a pristine home: junctions do not survive zip extraction
# as links, and dsh refuses a non-symlink fallback entry. The target machine
# re-initializes the home on first run.
Remove-Item -Recurse -Force (Join-Path $pkg 'dsh-home') -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'dsh-home') | Out-Null

# ── 8. zip + checksums ───────────────────────────────────────────────────────
$zipName = "DeepSeek-Harness-win64-v$DshVersion.zip"
$zipPath = Join-Path $dist $zipName
Write-Output "=== zipping $zipName ==="
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
if (Get-Command tar -ErrorAction SilentlyContinue) {
  tar -a -c -f $zipPath -C $profile 'DeepSeek-Harness'
  if ($LASTEXITCODE -ne 0) { throw "zip creation via tar failed (exit $LASTEXITCODE)" }
} else {
  Compress-Archive -Path (Join-Path $profile 'DeepSeek-Harness') -DestinationPath $zipPath -CompressionLevel Optimal
}
$sha = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
"$sha  $zipName" | Set-Content (Join-Path $dist 'SHA256SUMS.txt')

$sizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Output "=== DONE: $zipPath ($sizeMb MB) ==="
Write-Output "SHA256: $sha"
