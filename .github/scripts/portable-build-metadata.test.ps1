#requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'portable-build-metadata.ps1')

function Assert-Throws {
  param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Pattern)
  try { & $Action } catch {
    if ([string]$_.Exception.Message -like $Pattern) { return }
    throw "unexpected failure: $($_.Exception.Message)"
  }
  throw "expected failure matching $Pattern"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-build-metadata-' + [guid]::NewGuid().ToString('N'))
$modulesRoot = Join-Path $testRoot 'node_modules'
$clientRoot = Join-Path $modulesRoot '@deepseek-ai\dsh-client-test\lib'
$binRoot = Join-Path $modulesRoot '.bin'
try {
  New-Item -ItemType Directory -Force -Path $clientRoot, $binRoot | Out-Null
  $clientPath = Join-Path $clientRoot 'client.js'
  @'
function client() { return true }
  //#region \0dsh-css:D:\runner\_work\source\packages\client\test\src\client\view.css.mjs
  //#endregion
  //#region \0dsh-inline-css:/home/runner/work/source/packages/client/test/src/styles/base.css.mjs
  //#endregion
'@ | Set-Content -LiteralPath $clientPath -Encoding utf8NoBOM
  $shimPath = Join-Path $binRoot 'dsh'
  @'
#!/bin/sh
# cmd-shim-target=C:/Users/runneradmin/AppData/Local/Temp/dsh-portable-build/app/node_modules/@deepseek-ai/dsh/lib/bin.js
exec node dsh.js "$@"
'@ | Set-Content -LiteralPath $shimPath -Encoding utf8NoBOM

  $result = Normalize-DshPortableBuildMetadata $modulesRoot
  if ($result.SourceAnnotations -ne 2 -or $result.ShimAnnotations -ne 1) {
    throw "unexpected normalization counts: $($result | ConvertTo-Json -Compress)"
  }
  Assert-DshPortableBuildMetadataClean $modulesRoot
  $normalizedClient = Get-Content -LiteralPath $clientPath -Raw
  if (-not $normalizedClient.Contains('//#region \0dsh-css:packages/client/test/src/client/view.css.mjs') -or
    -not $normalizedClient.Contains('//#region \0dsh-inline-css:packages/client/test/src/styles/base.css.mjs')) {
    throw 'generated source annotations did not retain repository-relative identity'
  }
  $normalizedShim = Get-Content -LiteralPath $shimPath -Raw
  if ($normalizedShim.Contains('cmd-shim-target=') -or -not $normalizedShim.Contains('exec node dsh.js')) {
    throw 'shim normalization removed executable content or retained its build target'
  }
  Write-Output 'PASS generated metadata normalization preserves executable content and relative source labels'

  Add-Content -LiteralPath $clientPath -Value '//#region \0dsh-css:C:\private\packages\client\test\src\leak.css.mjs'
  Assert-Throws -Pattern '*absolute generated source annotation*' -Action {
    Assert-DshPortableBuildMetadataClean $modulesRoot
  }
  Write-Output 'PASS absolute generated source annotations fail closed'

  $cleanClient = $normalizedClient
  Set-Content -LiteralPath $clientPath -Value $cleanClient -Encoding utf8NoBOM -NoNewline
  Add-Content -LiteralPath $shimPath -Value '# cmd-shim-target=/tmp/private/dsh.js'
  Assert-Throws -Pattern '*package-manager build target annotation*' -Action {
    Assert-DshPortableBuildMetadataClean $modulesRoot
  }
  Write-Output 'PASS package-manager build target annotations fail closed'

  $portableRoot = Join-Path $testRoot 'portable-tree'
  $sensitiveRoot = Join-Path $testRoot 'private build source'
  New-Item -ItemType Directory -Path $portableRoot, $sensitiveRoot | Out-Null
  $probePath = Join-Path $portableRoot 'probe.txt'
  Set-Content -LiteralPath $probePath -Value 'portable content without a source path' -Encoding utf8NoBOM
  $scan = Assert-DshPortableTreeHasNoSensitivePaths -Root $portableRoot -SensitivePaths @($sensitiveRoot)
  if ($scan.Files -ne 1 -or $scan.Patterns -lt 4) { throw 'portable path scan returned inconsistent evidence' }
  Write-Output 'PASS portable tree path scan accepts clean content'

  Set-Content -LiteralPath $probePath -Value ([IO.Path]::GetFullPath($sensitiveRoot).Replace('\', '/')) -Encoding utf8NoBOM
  Assert-Throws -Pattern '*build-machine path*' -Action {
    Assert-DshPortableTreeHasNoSensitivePaths -Root $portableRoot -SensitivePaths @($sensitiveRoot)
  }
  Write-Output 'PASS portable tree path scan rejects slash-normalized paths'

  Set-Content -LiteralPath $probePath -Value ([Uri]::EscapeDataString([IO.Path]::GetFullPath($sensitiveRoot))) -Encoding utf8NoBOM
  Assert-Throws -Pattern '*build-machine path*' -Action {
    Assert-DshPortableTreeHasNoSensitivePaths -Root $portableRoot -SensitivePaths @($sensitiveRoot)
  }
  Write-Output 'PASS portable tree path scan rejects URI-encoded paths'

  Set-Content -LiteralPath $probePath -Value ([IO.Path]::GetFullPath($sensitiveRoot)) -Encoding unicode
  Assert-Throws -Pattern '*build-machine path*' -Action {
    Assert-DshPortableTreeHasNoSensitivePaths -Root $portableRoot -SensitivePaths @($sensitiveRoot)
  }
  Write-Output 'PASS portable tree path scan rejects UTF-16 paths'

  $fakeUserHome = Join-Path ([IO.Path]::GetPathRoot($testRoot)) 'Users\fixture-runner'
  Set-Content -LiteralPath $probePath -Value (Join-Path $fakeUserHome '.cache\tool') -Encoding utf8NoBOM
  Assert-Throws -Pattern '*build-machine path*' -Action {
    Assert-DshPortableTreeHasNoSensitivePaths -Root $portableRoot -SensitivePaths @($fakeUserHome)
  }
  Write-Output 'PASS portable tree path scan rejects non-temporary user-home paths'
  Write-Output 'PASS all portable build metadata tests'
} finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
