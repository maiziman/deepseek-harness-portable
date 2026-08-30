# Exact runtime-closure and local-package tests for the portable pnpm lock.
#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'pnpm-lock-policy.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-pnpm-lock-policy-' + [guid]::NewGuid().ToString('N'))
function Save-Lock {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string[]]$Packages,
    [Parameter(Mandatory)][string[]]$Snapshots,
    [Collections.IDictionary]$SnapshotBodies = @{},
    [string[]]$ControlLines
  )
  if ($null -eq $ControlLines) { $ControlLines = $script:validControlLines }
  $lines = @("lockfileVersion: '9.0'") + $ControlLines + @('', 'packages:', '') + $Packages + @('', 'snapshots:', '')
  foreach ($snapshot in $Snapshots) {
    [string[]]$body = if ($SnapshotBodies.Contains($snapshot)) { @($SnapshotBodies[$snapshot]) } else { @() }
    if ($snapshot.Length -gt 80) {
      $lines += "  ? '$snapshot'"
      $lines += $(if (@($body).Count -eq 0) { '  : {}' } else { '  :' })
    } else {
      $lines += $(if (@($body).Count -eq 0) { "  '$snapshot': {}" } else { "  '$snapshot':" })
    }
    $lines += $body
  }
  $lines | Set-Content -LiteralPath $Path -Encoding utf8
}
function Assert-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
  try { & $Action } catch {
    if ($_.Exception.Message -notmatch $Pattern) { throw "$Name threw an unexpected error: $($_.Exception.Message)" }
    Write-Output "PASS $Name"
    return
  }
  throw "$Name did not reject invalid input"
}
function Copy-SnapshotBodies([Collections.IDictionary]$Source) {
  $copy = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
  foreach ($key in $Source.Keys) { $copy.Add([string]$key, @($Source[$key])) }
  return ,$copy
}
function New-ResolutionRecord(
  [string]$SnapshotKey,
  [string]$PackageKey,
  [object]$Resolution,
  [object]$Snapshot = ([pscustomobject]@{}),
  [object]$Package = ([pscustomobject]@{})
) {
  $identity = Get-DshPnpmPackageKeyIdentity -PackageKey $PackageKey
  return [pscustomobject]@{
    snapshotKey = $SnapshotKey
    packageKey = $PackageKey
    packageName = [string]$identity.Name
    packageVersion = [string]$identity.Locator
    package = $Package
    resolution = $Resolution
    snapshot = $Snapshot
  }
}
function New-InternalSnapshotRecord(
  [string]$SnapshotKey,
  [string]$PackageKey,
  [string]$PackageVersion,
  [object]$Snapshot
) {
  $identity = Get-DshPnpmPackageKeyIdentity -PackageKey $PackageKey
  return [pscustomobject]@{
    snapshotKey = $SnapshotKey
    packageKey = $PackageKey
    packageName = [string]$identity.Name
    packageVersion = $PackageVersion
    package = if ($PackageVersion) { [pscustomobject]@{ version = $PackageVersion } } else { [pscustomobject]@{} }
    snapshot = $Snapshot
  }
}

$internalAllowlist = @(
  [pscustomobject]@{
    Name = '@deepseek-ai/dsh'
    Version = '0.1.2-alpha.1'
    RelativePath = '../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz'
  }
  [pscustomobject]@{
    Name = '@deepseek-ai/dsh-core'
    Version = ''
    RelativePath = '../verified/dsh-core'
  }
  [pscustomobject]@{
    Name = '@deepseek-ai/dsh-link'
    Version = ''
    Protocol = 'link'
    RelativePath = '../verified/dsh-link'
  }
)
$peerSnapshot = 'beta@2.0.0(@deepseek-ai/dsh@file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz)'
$patchSnapshot = 'patched@3.0.0(patch_hash=0123456789abcdef)'
$otherBetaSnapshot = 'beta@2.1.0'
$dshPackageKey = '@deepseek-ai/dsh@file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz'
$dshSnapshot = "$dshPackageKey(peer-hash)"
$corePackageKey = '@deepseek-ai/dsh-core@file:../verified/dsh-core'
$coreSnapshot = "$corePackageKey(peer-hash)"
$linkPackageKey = '@deepseek-ai/dsh-link@link:../verified/dsh-link'
$expectedControl = [pscustomobject][ordered]@{
  importers = [pscustomobject][ordered]@{
    '.' = [pscustomobject][ordered]@{
      dependencies = [pscustomobject][ordered]@{
        '@deepseek-ai/dsh' = [pscustomobject][ordered]@{
          specifier = 'file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz'
          version = 'file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz(peer-hash)'
        }
        alpha = [pscustomobject][ordered]@{ specifier = '1.0.0'; version = '1.0.0' }
      }
    }
  }
  lockfileVersion = '9.0'
  overrides = [pscustomobject][ordered]@{
    '@deepseek-ai/dsh' = 'file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz'
    alpha = '1.0.0'
  }
  patchedDependencies = [pscustomobject][ordered]@{
    'patched@3.0.0' = '0123456789abcdef'
  }
  settings = [pscustomobject][ordered]@{
    autoInstallPeers = $true
    excludeLinksFromLockfile = $false
  }
}
$validControlLines = @(
  'settings:'
  '  autoInstallPeers: true'
  '  excludeLinksFromLockfile: false'
  'overrides:'
  "  '@deepseek-ai/dsh': file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz"
  '  alpha: 1.0.0'
  'patchedDependencies:'
  "  'patched@3.0.0': 0123456789abcdef"
  'importers:'
  '  .:'
  '    dependencies:'
  "      '@deepseek-ai/dsh':"
  '        specifier: file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz'
  '        version: file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz(peer-hash)'
  '      alpha:'
  '        specifier: 1.0.0'
  '        version: 1.0.0'
)
$PSDefaultParameterValues['Assert-DshPnpmLockMatchesRuntimeResolutions:ExpectedConsumerLockControl'] = $expectedControl
$expected = @(
  (New-ResolutionRecord 'alpha@1.0.0' 'alpha@1.0.0' ([pscustomobject]@{ integrity = 'sha512-alpha' }) ([pscustomobject]@{
    dependencies = [pscustomobject]@{ beta = "2.0.0(@deepseek-ai/dsh@file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz)" }
    optionalDependencies = [pscustomobject]@{ patched = '3.0.0(patch_hash=0123456789abcdef)' }
    transitivePeerDependencies = @('zod')
  }) ([pscustomobject]@{
    cpu = @('x64')
    engines = [pscustomobject]@{ node = '>=22' }
    hasBin = $true
    libc = @('glibc')
    os = @('win32')
    peerDependencies = [pscustomobject]@{ beta = '^2.0.0' }
    peerDependenciesMeta = [pscustomobject]@{ beta = [pscustomobject]@{ optional = $true } }
  }))
  (New-ResolutionRecord $peerSnapshot 'beta@2.0.0' ([ordered]@{
    integrity = 'sha512-beta'
    tarball = 'https://registry.example/beta-2.0.0.tgz'
  }) ([pscustomobject]@{ optional = $true }))
  (New-ResolutionRecord $otherBetaSnapshot 'beta@2.1.0' ([pscustomobject]@{ integrity = 'sha512-beta-21' }))
  (New-ResolutionRecord $patchSnapshot 'patched@3.0.0' ([pscustomobject]@{ integrity = 'sha512-patched' }))
)
$expectedInternal = @(
  (New-InternalSnapshotRecord $dshSnapshot $dshPackageKey '0.1.2-alpha.1' ([pscustomobject]@{
    dependencies = [pscustomobject]@{
      '@deepseek-ai/dsh-core' = 'file:../verified/dsh-core(peer-hash)'
      alpha = '1.0.0'
    }
    optionalDependencies = [pscustomobject]@{ beta = '2.0.0(@deepseek-ai/dsh@file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz)' }
    transitivePeerDependencies = @('zod')
  }))
  (New-InternalSnapshotRecord $coreSnapshot $corePackageKey '' ([pscustomobject]@{
    dependencies = [pscustomobject]@{ '@deepseek-ai/dsh-link' = 'link:../verified/dsh-link' }
  }))
  (New-InternalSnapshotRecord $linkPackageKey $linkPackageKey '' ([pscustomobject]@{}))
)
$validPackages = @(
  "  'alpha@1.0.0':"
  '    resolution:'
  '      integrity: sha512-alpha'
  '    engines:'
  "      node: '>=22'"
  '    cpu:'
  '      - x64'
  '    os:'
  '      - win32'
  '    libc:'
  '      - glibc'
  '    hasBin: true'
  '    peerDependencies:'
  '      beta: ^2.0.0'
  '    peerDependenciesMeta:'
  '      beta:'
  '        optional: true'
  "  'beta@2.0.0':"
  "    resolution: {tarball: 'https://registry.example/beta-2.0.0.tgz', integrity: sha512-beta}"
  "  'beta@2.1.0':"
  '    resolution: {integrity: sha512-beta-21}'
  "  'patched@3.0.0':"
  '    resolution: {integrity: sha512-patched}'
  "  '@deepseek-ai/dsh@file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz':"
  '    resolution: {tarball: file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz, integrity: sha512-dsh}'
  '    version: 0.1.2-alpha.1'
  "  '@deepseek-ai/dsh-core@file:../verified/dsh-core':"
  '    resolution: {type: directory, directory: ../verified/dsh-core}'
  "  '@deepseek-ai/dsh-link@link:../verified/dsh-link':"
  '    resolution: {directory: ../verified/dsh-link, type: directory}'
)
$validSnapshots = @(
  'alpha@1.0.0'
  $peerSnapshot
  $otherBetaSnapshot
  $patchSnapshot
  $dshSnapshot
  $coreSnapshot
  $linkPackageKey
)
$validSnapshotBodies = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
$validSnapshotBodies.Add('alpha@1.0.0', @(
  '    dependencies:'
  "      beta: 2.0.0(@deepseek-ai/dsh@file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz)"
  '    optionalDependencies:'
  '      patched: 3.0.0(patch_hash=0123456789abcdef)'
  '    transitivePeerDependencies:'
  '      - zod'
))
$validSnapshotBodies.Add($peerSnapshot, @('    optional: true'))
$validSnapshotBodies.Add($dshSnapshot, @(
  '    dependencies:'
  '      @deepseek-ai/dsh-core: file:../verified/dsh-core(peer-hash)'
  '      alpha: 1.0.0'
  '    optionalDependencies:'
  '      beta: 2.0.0(@deepseek-ai/dsh@file:../verified/deepseek-ai-dsh-0.1.2-alpha.1.tgz)'
  '    transitivePeerDependencies:'
  '      - zod'
))
$validSnapshotBodies.Add($coreSnapshot, @(
  '    dependencies:'
  '      @deepseek-ai/dsh-link: link:../verified/dsh-link'
))

New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  $valid = Join-Path $testRoot 'valid.yaml'
  Save-Lock -Path $valid -Packages $validPackages -Snapshots $validSnapshots -SnapshotBodies $validSnapshotBodies
  $result = Assert-DshPnpmLockMatchesRuntimeResolutions `
    -CandidateLockPath $valid `
    -ExpectedResolutions $expected `
    -ExpectedInternalSnapshots $expectedInternal `
    -InternalPackageAllowlist $internalAllowlist
  if ($result.CandidateCount -ne 4 -or $result.OfficialCount -ne 4 -or $result.InternalCount -ne 3) {
    throw 'valid runtime lock comparison returned incorrect counts'
  }
  Write-Output 'PASS exact external runtime closure plus allowlisted tgz, directory, and link packages'
  Write-Output 'PASS external peer suffix containing @file: remains an external snapshot'
  Write-Output 'PASS patch snapshot key resolves to its exact registry package record'
  Write-Output 'PASS external integrity/tarball field order is normalized'

  $deletedRootDependencyLines = [Collections.Generic.List[string]]::new([string[]]$validControlLines)
  $deletedRootDependencyIndex = $deletedRootDependencyLines.IndexOf("      '@deepseek-ai/dsh':")
  $deletedRootDependencyLines.RemoveRange($deletedRootDependencyIndex, 3)
  $deletedRootDependency = Join-Path $testRoot 'deleted-root-dependency.yaml'
  Save-Lock `
    -Path $deletedRootDependency `
    -Packages $validPackages `
    -Snapshots $validSnapshots `
    -SnapshotBodies $validSnapshotBodies `
    -ControlLines @($deletedRootDependencyLines)
  Assert-Throws 'root importer dependency deleted' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $deletedRootDependency `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'lock control differs'

  foreach ($controlMutation in @(
    [pscustomobject]@{
      Name = 'root setting changed'
      File = 'changed-root-setting.yaml'
      Pattern = '^  autoInstallPeers: true$'
      Replacement = '  autoInstallPeers: false'
    }
    [pscustomobject]@{
      Name = 'root override changed'
      File = 'changed-root-override.yaml'
      Pattern = '^  alpha: 1\.0\.0$'
      Replacement = '  alpha: 2.1.0'
    }
    [pscustomobject]@{
      Name = 'root patch changed'
      File = 'changed-root-patch.yaml'
      Pattern = "^  'patched@3\.0\.0': 0123456789abcdef$"
      Replacement = "  'patched@3.0.0': fedcba9876543210"
    }
  )) {
    $controlLines = @($validControlLines | ForEach-Object { $_ -replace $controlMutation.Pattern, $controlMutation.Replacement })
    $path = Join-Path $testRoot $controlMutation.File
    Save-Lock `
      -Path $path `
      -Packages $validPackages `
      -Snapshots $validSnapshots `
      -SnapshotBodies $validSnapshotBodies `
      -ControlLines $controlLines
    Assert-Throws $controlMutation.Name {
      Assert-DshPnpmLockMatchesRuntimeResolutions `
        -CandidateLockPath $path `
        -ExpectedResolutions $expected `
        -ExpectedInternalSnapshots $expectedInternal `
        -InternalPackageAllowlist $internalAllowlist
    } 'lock control differs'
  }

  $unknownRoot = Join-Path $testRoot 'unknown-root-field.yaml'
  Save-Lock `
    -Path $unknownRoot `
    -Packages $validPackages `
    -Snapshots $validSnapshots `
    -SnapshotBodies $validSnapshotBodies `
    -ControlLines @($validControlLines + @('catalogs:', '  fixture: 1.0.0'))
  Assert-Throws 'unknown root field' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $unknownRoot `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'unsupported root field: catalogs'

  $unknownSetting = Join-Path $testRoot 'unknown-root-setting.yaml'
  $unknownSettingLines = [Collections.Generic.List[string]]::new([string[]]$validControlLines)
  $unknownSettingLines.Insert(3, '  injectWorkspacePackages: true')
  Save-Lock `
    -Path $unknownSetting `
    -Packages $validPackages `
    -Snapshots $validSnapshots `
    -SnapshotBodies $validSnapshotBodies `
    -ControlLines @($unknownSettingLines)
  Assert-Throws 'unknown root setting' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $unknownSetting `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'settings has unsupported field injectWorkspacePackages'

  $redirectedExternalBodies = Copy-SnapshotBodies $validSnapshotBodies
  $redirectedExternalBodies['alpha@1.0.0'] = @($redirectedExternalBodies['alpha@1.0.0'] | ForEach-Object {
    $_ -replace '^      beta: 2\.0\.0', '      beta: 2.1.0'
  })
  $redirectedExternal = Join-Path $testRoot 'redirected-external-edge.yaml'
  Save-Lock -Path $redirectedExternal -Packages $validPackages -Snapshots $validSnapshots -SnapshotBodies $redirectedExternalBodies
  Assert-Throws 'external edge redirected to another present version' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $redirectedExternal `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'resolution differs.*alpha@1\.0\.0'

  $redirectedInternalBodies = Copy-SnapshotBodies $validSnapshotBodies
  $redirectedInternalBodies[$dshSnapshot] = @($redirectedInternalBodies[$dshSnapshot] | ForEach-Object {
    $_ -replace '^      beta: 2\.0\.0', '      beta: 2.1.0'
  })
  $redirectedInternal = Join-Path $testRoot 'redirected-internal-edge.yaml'
  Save-Lock -Path $redirectedInternal -Packages $validPackages -Snapshots $validSnapshots -SnapshotBodies $redirectedInternalBodies
  Assert-Throws 'internal edge redirected to another present external version' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $redirectedInternal `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'internal snapshot differs.*@deepseek-ai/dsh@file:'

  $redirectedLocalBodies = Copy-SnapshotBodies $validSnapshotBodies
  $redirectedLocalBodies[$dshSnapshot] = @($redirectedLocalBodies[$dshSnapshot] | ForEach-Object {
    $_ -replace 'file:\.\./verified/dsh-core\(peer-hash\)', 'link:../verified/dsh-link'
  })
  $redirectedLocal = Join-Path $testRoot 'redirected-local-edge.yaml'
  Save-Lock -Path $redirectedLocal -Packages $validPackages -Snapshots $validSnapshots -SnapshotBodies $redirectedLocalBodies
  Assert-Throws 'internal edge redirected to another present local package' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $redirectedLocal `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'internal snapshot differs.*@deepseek-ai/dsh@file:'

  $redirectedTransitiveBodies = Copy-SnapshotBodies $validSnapshotBodies
  $redirectedTransitiveBodies['alpha@1.0.0'] = @($redirectedTransitiveBodies['alpha@1.0.0'] | ForEach-Object {
    $_ -replace '^      - zod$', '      - react'
  })
  $redirectedTransitive = Join-Path $testRoot 'redirected-transitive-peer.yaml'
  Save-Lock -Path $redirectedTransitive -Packages $validPackages -Snapshots $validSnapshots -SnapshotBodies $redirectedTransitiveBodies
  Assert-Throws 'external transitive peer changed' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $redirectedTransitive `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'resolution differs.*alpha@1\.0\.0'

  $hasBinFalse = Join-Path $testRoot 'has-bin-false.yaml'
  $hasBinFalsePackages = @($validPackages | ForEach-Object { $_ -replace '^    hasBin: true$', '    hasBin: false' })
  Save-Lock -Path $hasBinFalse -Packages $hasBinFalsePackages -Snapshots $validSnapshots -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'external hasBin false' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $hasBinFalse `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'package metadata differs.*alpha@1\.0\.0'

  $wrongPlatform = Join-Path $testRoot 'wrong-package-platform.yaml'
  $wrongPlatformPackages = @($validPackages | ForEach-Object { $_ -replace '^      - win32$', '      - linux' })
  Save-Lock -Path $wrongPlatform -Packages $wrongPlatformPackages -Snapshots $validSnapshots -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'external package platform changed' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $wrongPlatform `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'package metadata differs.*alpha@1\.0\.0'

  $wrongPeerMeta = Join-Path $testRoot 'wrong-peer-meta.yaml'
  $wrongPeerMetaPackages = @($validPackages | ForEach-Object { $_ -replace '^        optional: true$', '        optional: false' })
  Save-Lock -Path $wrongPeerMeta -Packages $wrongPeerMetaPackages -Snapshots $validSnapshots -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'external package peer metadata changed' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $wrongPeerMeta `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'package metadata differs.*alpha@1\.0\.0'

  $unknownPackageField = Join-Path $testRoot 'unknown-package-field.yaml'
  $unknownPackageFieldPackages = @($validPackages | ForEach-Object {
    $_
    if ($_ -ceq '    hasBin: true') { '    requiresBuild: true' }
  })
  Save-Lock -Path $unknownPackageField -Packages $unknownPackageFieldPackages -Snapshots $validSnapshots -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'unknown package field' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $unknownPackageField `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'unsupported or malformed body line.*requiresBuild'

  $internalPackageMetadata = Join-Path $testRoot 'internal-package-metadata.yaml'
  $internalPackageMetadataPackages = [Collections.Generic.List[string]]::new()
  $insideDsh = $false
  foreach ($line in $validPackages) {
    if ($line -ceq "  '$dshPackageKey':") { $insideDsh = $true }
    if ($insideDsh -and $line -ceq '    version: 0.1.2-alpha.1') {
      $internalPackageMetadataPackages.Add('    hasBin: false')
      $insideDsh = $false
    }
    $internalPackageMetadataPackages.Add($line)
  }
  Save-Lock -Path $internalPackageMetadata -Packages @($internalPackageMetadataPackages) -Snapshots $validSnapshots -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'internal package metadata changed' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $internalPackageMetadata `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'internal package metadata differs.*@deepseek-ai/dsh@file:'

  $unknownSnapshotBodies = Copy-SnapshotBodies $validSnapshotBodies
  $unknownSnapshotBodies['alpha@1.0.0'] = @($unknownSnapshotBodies['alpha@1.0.0']) + '    dev: true'
  $unknownSnapshot = Join-Path $testRoot 'unknown-snapshot-field.yaml'
  Save-Lock -Path $unknownSnapshot -Packages $validPackages -Snapshots $validSnapshots -SnapshotBodies $unknownSnapshotBodies
  Assert-Throws 'unknown install-affecting snapshot field' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $unknownSnapshot `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'unsupported or malformed body line.*dev'

  $unknownNestedResolution = Join-Path $testRoot 'unknown-nested-resolution.yaml'
  $unknownNestedPackages = @($validPackages | ForEach-Object {
    $_
    if ($_ -ceq '      integrity: sha512-alpha') { '      unexpected: value' }
  })
  Save-Lock -Path $unknownNestedResolution -Packages $unknownNestedPackages -Snapshots $validSnapshots -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'unknown nested resolution field' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $unknownNestedResolution `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'unsupported resolution field: unexpected'

  $duplicateNestedResolution = Join-Path $testRoot 'duplicate-nested-resolution.yaml'
  $duplicateNestedPackages = @($validPackages | ForEach-Object {
    $_
    if ($_ -ceq '      integrity: sha512-alpha') { '      integrity: sha512-other' }
  })
  Save-Lock -Path $duplicateNestedResolution -Packages $duplicateNestedPackages -Snapshots $validSnapshots -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'duplicate nested resolution field' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $duplicateNestedResolution `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'resolution duplicates field: integrity'

  $extra = Join-Path $testRoot 'extra-version.yaml'
  Save-Lock -Path $extra `
    -Packages ($validPackages + @(
      "  'iconv-lite@0.6.3':"
      '    resolution: {integrity: sha512-iconv}'
    )) `
    -Snapshots ($validSnapshots + 'iconv-lite@0.6.3') `
    -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'full-lock-only external version' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $extra `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'iconv-lite@0\.6\.3'

  $missing = Join-Path $testRoot 'missing-runtime.yaml'
  Save-Lock -Path $missing `
    -Packages @($validPackages | Where-Object { $_ -notmatch "beta@2\.0\.0|registry\.example/beta" }) `
    -Snapshots @($validSnapshots | Where-Object { $_ -cne $peerSnapshot }) `
    -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'missing official runtime version' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $missing `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'missing an official production snapshot.*beta@2\.0\.0'

  $wrongIdentity = @($expected | ForEach-Object {
    if ($_.snapshotKey -ceq 'alpha@1.0.0') {
      [pscustomobject]@{
        snapshotKey = $_.snapshotKey
        packageKey = $_.packageKey
        packageName = 'evil'
        packageVersion = $_.packageVersion
        resolution = $_.resolution
      }
    } else { $_ }
  })
  Assert-Throws 'official record package identity mismatch' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $valid `
      -ExpectedResolutions $wrongIdentity `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'inconsistent package identity.*alpha@1\.0\.0'

  $wrongResolution = @($expected | ForEach-Object {
    if ($_.snapshotKey -ceq 'alpha@1.0.0') {
      New-ResolutionRecord $_.snapshotKey $_.packageKey ([pscustomobject]@{ integrity = 'sha512-wrong' }) $_.snapshot $_.package
    } else { $_ }
  })
  Assert-Throws 'official record resolution mismatch' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $valid `
      -ExpectedResolutions $wrongResolution `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'resolution differs.*alpha@1\.0\.0'

  $unknownFile = Join-Path $testRoot 'unknown-file.yaml'
  Save-Lock -Path $unknownFile `
    -Packages ($validPackages + @(
      "  'evil@file:../evil.tgz':"
      '    resolution: {integrity: sha512-evil, tarball: file:../evil.tgz}'
      '    version: 1.0.0'
    )) `
    -Snapshots ($validSnapshots + 'evil@file:../evil.tgz') `
    -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'unknown file package' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $unknownFile `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'unknown local package.*evil@file:'

  $unknownLink = Join-Path $testRoot 'unknown-link.yaml'
  Save-Lock -Path $unknownLink `
    -Packages ($validPackages + @(
      "  'evil@link:../evil':"
      '    resolution: {directory: ../evil, type: directory}'
    )) `
    -Snapshots ($validSnapshots + 'evil@link:../evil') `
    -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'unknown link package' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $unknownLink `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'unknown local package.*evil@link:'

  $unknownDirectory = Join-Path $testRoot 'unknown-directory.yaml'
  Save-Lock -Path $unknownDirectory `
    -Packages ($validPackages + @(
      "  'evil@1.0.0':"
      '    resolution: {directory: ../evil, type: directory}'
    )) `
    -Snapshots ($validSnapshots + 'evil@1.0.0') `
    -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'unknown directory resolution' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $unknownDirectory `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'non-registry resolution.*evil@1\.0\.0'

  $wrongTarball = Join-Path $testRoot 'wrong-tarball.yaml'
  $wrongTarballPackages = @($validPackages | ForEach-Object {
    $_ -replace 'tarball: file:\.\./verified/deepseek-ai-dsh-0\.1\.2-alpha\.1\.tgz', 'tarball: file:../evil/deepseek-ai-dsh-0.1.2-alpha.1.tgz'
  })
  Save-Lock -Path $wrongTarball -Packages $wrongTarballPackages -Snapshots $validSnapshots -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'allowlisted tgz path mismatch' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $wrongTarball `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'tarball has an unexpected resolution'

  $wrongLocalVersion = Join-Path $testRoot 'wrong-local-version.yaml'
  $wrongLocalVersionPackages = @($validPackages | ForEach-Object {
    if ($_ -ceq '    version: 0.1.2-alpha.1') { '    version: 9.9.9' } else { $_ }
  })
  Save-Lock -Path $wrongLocalVersion -Packages $wrongLocalVersionPackages -Snapshots $validSnapshots -SnapshotBodies $validSnapshotBodies
  Assert-Throws 'allowlisted tgz package version mismatch' {
    Assert-DshPnpmLockMatchesRuntimeResolutions `
      -CandidateLockPath $wrongLocalVersion `
      -ExpectedResolutions $expected `
      -ExpectedInternalSnapshots $expectedInternal `
      -InternalPackageAllowlist $internalAllowlist
  } 'tarball has the wrong package version'

  Write-Output 'PASS all pnpm runtime lock policy tests'
} finally {
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\', [char]'/')
  $resolved = [IO.Path]::GetFullPath($testRoot)
  if (-not $resolved.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path $resolved -Leaf) -cnotlike 'dsh-pnpm-lock-policy-*') {
    throw "refusing to clean unexpected test directory: $resolved"
  }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
