# Negative and end-to-end tests for official tagged-source package staging.
#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptsRoot = $PSScriptRoot
. (Join-Path $scriptsRoot 'official-dsh-package-input.ps1')
$stageScript = Join-Path $scriptsRoot 'stage-official-dsh-packages.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-official-package-input-' + [guid]::NewGuid().ToString('N'))
$version = '0.1.2-alpha.1'
$sourceTag = "dsh-v$version"

function New-TestArchive {
  param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Version,
    [hashtable]$Dependencies = @{}
  )

  $packingRoot = Join-Path $testRoot ('packing-' + [guid]::NewGuid().ToString('N'))
  $packageRoot = Join-Path $packingRoot 'package'
  New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
  [ordered]@{
    name = $Name
    version = $Version
    dependencies = $Dependencies
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $packageRoot 'package.json') -Encoding utf8
  New-Item -ItemType Directory -Path (Split-Path $ArchivePath -Parent) -Force | Out-Null
  & tar -czf $ArchivePath -C $packingRoot package
  if ($LASTEXITCODE -ne 0) { throw "test tar creation failed: $ArchivePath" }
}

function Save-TestProvenance {
  param(
    [Parameter(Mandatory)][string]$InputDirectory,
    [Parameter(Mandatory)][object]$Provenance
  )

  $Provenance.packageCount = @($Provenance.packages).Count
  $Provenance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $InputDirectory 'provenance.json') -Encoding utf8
  (@($Provenance.packages) | Sort-Object relativePath | ForEach-Object { "$($_.sha256)  $($_.relativePath)" }) -join "`n" |
    Set-Content -LiteralPath (Join-Path $InputDirectory 'SHA256SUMS.txt') -Encoding utf8 -NoNewline
}

function Copy-TestInput {
  param([Parameter(Mandatory)][string]$Baseline, [Parameter(Mandatory)][string]$Name)

  $target = Join-Path $testRoot $Name
  Copy-Item -LiteralPath $Baseline -Destination $target -Recurse
  return $target
}

function Set-TestConsumerHashes {
  param(
    [Parameter(Mandatory)][string]$InputDirectory,
    [Parameter(Mandatory)][object]$Provenance
  )

  $consumerRoot = Join-Path $InputDirectory 'consumer'
  $Provenance.consumerFiles = @(Get-ChildItem -LiteralPath $consumerRoot -File | Sort-Object Name | ForEach-Object {
    [pscustomobject][ordered]@{
      relativePath = [string]$_.Name
      size = [int64]$_.Length
      sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  })
}

function New-FinalizedTestInput {
  param(
    [Parameter(Mandatory)][string]$Baseline,
    [Parameter(Mandatory)][string]$Name
  )

  $target = Copy-TestInput -Baseline $Baseline -Name $Name
  $provenance = Get-Content -LiteralPath (Join-Path $target 'provenance.json') -Raw | ConvertFrom-Json
  $dshRecord = @($provenance.packages | Where-Object { $_.name -ceq '@deepseek-ai/dsh' })
  if ($dshRecord.Count -ne 1) { throw 'finalized fixture has no unique dsh archive record' }
  $runtimeResolutions = @(for ($index = 0; $index -lt 50; $index++) {
    $name = 'fixture-package-{0:d2}' -f $index
    $snapshot = if ($index -lt 49) {
      $nextName = 'fixture-package-{0:d2}' -f ($index + 1)
      [pscustomobject][ordered]@{ dependencies = [pscustomobject][ordered]@{ $nextName = '1.0.0' } }
    } else {
      [pscustomobject][ordered]@{}
    }
    [pscustomobject][ordered]@{
      snapshotKey = "$name@1.0.0"
      packageKey = "$name@1.0.0"
      packageName = $name
      packageVersion = '1.0.0'
      package = [pscustomobject][ordered]@{}
      resolution = [pscustomobject][ordered]@{ integrity = 'sha512-Zml4dHVyZQ==' }
      snapshot = $snapshot
    }
  })
  $provenance.schemaVersion = 4
  $provenance | Add-Member -NotePropertyName target -NotePropertyValue 'win32-x64' -Force
  $provenance | Add-Member -NotePropertyName runtimeGraphDerivation -NotePropertyValue 'official-lock-importers-prod-optional-required-peers' -Force
  $provenance | Add-Member -NotePropertyName runtimeInternalPackageCount -NotePropertyValue 1 -Force
  $provenance | Add-Member -NotePropertyName runtimeInternalPackages -NotePropertyValue @(
    [pscustomobject][ordered]@{
      name = [string]$dshRecord[0].name
      version = [string]$dshRecord[0].version
      relativePath = [string]$dshRecord[0].relativePath
      sha256 = [string]$dshRecord[0].sha256
    }
  ) -Force
  $internalSnapshots = @(
    [pscustomobject][ordered]@{
      snapshotKey = '@deepseek-ai/dsh@file:../dsh/deepseek-ai-dsh.tgz'
      packageKey = '@deepseek-ai/dsh@file:../dsh/deepseek-ai-dsh.tgz'
      packageName = '@deepseek-ai/dsh'
      packageVersion = $version
      package = [pscustomobject][ordered]@{ version = $version }
      snapshot = [pscustomobject][ordered]@{
        dependencies = [pscustomobject][ordered]@{ 'fixture-package-00' = '1.0.0' }
      }
    }
  )
  $provenance | Add-Member -NotePropertyName internalSnapshotCount -NotePropertyValue $internalSnapshots.Count -Force
  $provenance | Add-Member -NotePropertyName internalRuntimeSnapshots -NotePropertyValue $internalSnapshots -Force
  $provenance | Add-Member -NotePropertyName internalRuntimeSnapshotsSha256 -NotePropertyValue (Get-DshCanonicalRecordsSha256 -Records $internalSnapshots) -Force
  $provenance | Add-Member -NotePropertyName externalResolutionCount -NotePropertyValue $runtimeResolutions.Count -Force
  $provenance | Add-Member -NotePropertyName runtimeResolutions -NotePropertyValue $runtimeResolutions -Force
  $provenance | Add-Member -NotePropertyName runtimeResolutionsSha256 -NotePropertyValue (Get-DshRuntimeResolutionsSha256 -Records $runtimeResolutions) -Force
  $provenance | Add-Member -NotePropertyName consumerPeerPins -NotePropertyValue ([pscustomobject][ordered]@{ zod = '4.4.3' }) -Force
  $provenance | Add-Member -NotePropertyName excludedWindowsOptionalPackages -NotePropertyValue ([pscustomobject][ordered]@{
    '@deepseek-ai/node-addon-landlock-run-linux-x64' = '0.1.1'
  }) -Force
  $provenance | Add-Member -NotePropertyName consumerOverrideCount -NotePropertyValue 1 -Force

  $consumerControl = [pscustomobject][ordered]@{
    importers = [pscustomobject][ordered]@{
      '.' = [pscustomobject][ordered]@{
        dependencies = [pscustomobject][ordered]@{
          '@deepseek-ai/dsh' = [pscustomobject][ordered]@{
            specifier = 'file:../dsh/deepseek-ai-dsh.tgz'
            version = 'file:../dsh/deepseek-ai-dsh.tgz'
          }
          zod = [pscustomobject][ordered]@{ specifier = '4.4.3'; version = '4.4.3' }
        }
      }
    }
    lockfileVersion = '9.0'
    overrides = [pscustomobject][ordered]@{ '@deepseek-ai/dsh' = 'file:../dsh/deepseek-ai-dsh.tgz' }
    patchedDependencies = [pscustomobject][ordered]@{
      'node-pty@1.2.0-beta.15' = 'b40ae5458a1978b112adae3279e35680d6a1a5988fd1f4cb8942e228da869abf'
    }
    settings = [pscustomobject][ordered]@{ autoInstallPeers = $true; excludeLinksFromLockfile = $false }
  }
  $provenance | Add-Member -NotePropertyName consumerLockControl -NotePropertyValue $consumerControl -Force
  $provenance | Add-Member -NotePropertyName consumerLockControlSha256 -NotePropertyValue (Get-DshCanonicalValueSha256 -Value $consumerControl) -Force

  $consumerRoot = Join-Path $target 'consumer'
  New-Item -ItemType Directory -Path $consumerRoot | Out-Null
  [ordered]@{
    name = 'deepseek-harness-portable-official-runtime'
    version = '0.0.0'
    private = $true
    packageManager = 'pnpm@11.7.0'
    dependencies = [ordered]@{
      '@deepseek-ai/dsh' = 'file:../dsh/deepseek-ai-dsh.tgz'
      zod = '4.4.3'
    }
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $consumerRoot 'package.json') -Encoding utf8
  @(
    "lockfileVersion: '9.0'"
    'settings:'
    '  autoInstallPeers: true'
    '  excludeLinksFromLockfile: false'
    'overrides:'
    "  '@deepseek-ai/dsh': file:../dsh/deepseek-ai-dsh.tgz"
    'patchedDependencies:'
    "  'node-pty@1.2.0-beta.15': b40ae5458a1978b112adae3279e35680d6a1a5988fd1f4cb8942e228da869abf"
    'importers:'
    '  .:'
    '    dependencies:'
    "      '@deepseek-ai/dsh':"
    '        specifier: file:../dsh/deepseek-ai-dsh.tgz'
    '        version: file:../dsh/deepseek-ai-dsh.tgz'
    '      zod:'
    '        specifier: 4.4.3'
    '        version: 4.4.3'
    'packages:'
    'snapshots:'
  ) -join "`n" | Set-Content -LiteralPath (Join-Path $consumerRoot 'pnpm-lock.yaml') -Encoding utf8
  Set-Content -LiteralPath (Join-Path $consumerRoot 'pnpm-workspace.yaml') -Value 'overrides: {}' -Encoding utf8
  $provenance | Add-Member -NotePropertyName consumerFiles -NotePropertyValue @() -Force
  Set-TestConsumerHashes -InputDirectory $target -Provenance $provenance
  Save-TestProvenance -InputDirectory $target -Provenance $provenance
  return $target
}

function Assert-Throws {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Action,
    [Parameter(Mandatory)][string]$MessagePattern
  )

  try {
    & $Action
  } catch {
    if ($_.Exception.Message -notmatch $MessagePattern) {
      throw "$Name threw an unexpected error: $($_.Exception.Message)"
    }
    Write-Output "PASS $Name"
    return
  }
  throw "$Name did not reject invalid input"
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  $source = Join-Path $testRoot 'source'
  New-Item -ItemType Directory -Path (Join-Path $source 'apps/cli') -Force | Out-Null
  [ordered]@{
    name = 'official-source-test'
    version = $version
    private = $true
    packageManager = 'pnpm@11.7.0'
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $source 'package.json') -Encoding utf8
  @(
    'allowBuilds:'
    "  '@deepseek-ai/dsh-subprocess-local@file:packages/subprocess/subprocess-local': true"
    '  node-pty: true'
    '  protobufjs: false'
    'patchedDependencies:'
    '  node-pty@1.2.0-beta.15: patches/node-pty@1.2.0-beta.15.patch'
  ) -join "`n" | Set-Content -LiteralPath (Join-Path $source 'pnpm-workspace.yaml') -Encoding utf8
  New-Item -ItemType Directory -Path (Join-Path $source 'patches') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $source 'patches/node-pty@1.2.0-beta.15.patch') -Value 'fixture patch' -Encoding utf8
  Set-Content -LiteralPath (Join-Path $source 'pnpm-lock.yaml') -Value "lockfileVersion: '9.0'`n" -Encoding utf8
  [ordered]@{
    name = '@deepseek-ai/dsh'
    version = $version
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $source 'apps/cli/package.json') -Encoding utf8

  New-TestArchive -ArchivePath (Join-Path $source 'dist/npm/deepseek-ai-dsh.tgz') -Name '@deepseek-ai/dsh' -Version $version
  New-TestArchive -ArchivePath (Join-Path $source 'dist/npm-vendor/deepseek-ai-cordis.tgz') -Name '@deepseek-ai/cordis' -Version '4.0.1'
  New-TestArchive -ArchivePath (Join-Path $source 'dist/npm-landlock/deepseek-ai-landlock.tgz') -Name '@deepseek-ai/node-addon-landlock-run' -Version '0.1.1'

  & git -C $source init --quiet
  if ($LASTEXITCODE -ne 0) { throw 'test git init failed' }
  & git -C $source config user.email 'portable-tests@example.invalid'
  & git -C $source config user.name 'Portable Tests'
  & git -C $source add package.json pnpm-lock.yaml pnpm-workspace.yaml patches apps/cli/package.json
  & git -C $source commit --quiet -m fixture
  if ($LASTEXITCODE -ne 0) { throw 'test git commit failed' }
  & git -C $source tag $sourceTag
  if ($LASTEXITCODE -ne 0) { throw 'test git tag failed' }
  $sourceSha = (& git -C $source rev-parse HEAD | Out-String).Trim()

  $baseline = Join-Path $testRoot 'baseline'
  & $stageScript `
    -SourceDirectory $source `
    -OutputDirectory $baseline `
    -ExpectedVersion $version `
    -ExpectedSourceTag $sourceTag `
    -ExpectedSourceSha $sourceSha | Out-Null
  Assert-Throws -Name 'unfinalized schema rejected by default' -MessagePattern 'unsupported format' -Action {
    Get-DshOfficialPackageInput `
      -Directory $baseline `
      -ExpectedVersion $version `
      -ExpectedSourceTag $sourceTag `
      -ExpectedSourceSha $sourceSha
  }
  $valid = Get-DshOfficialPackageInput `
    -Directory $baseline `
    -ExpectedVersion $version `
    -ExpectedSourceTag $sourceTag `
    -ExpectedSourceSha $sourceSha `
    -AllowUnfinalized
  if ($valid.Packages.Count -ne 3) { throw 'valid staged fixture did not contain three packages' }
  if (-not [bool]$valid.AllowBuilds['node-pty'] -or [bool]$valid.AllowBuilds['protobufjs']) {
    throw 'valid staged fixture did not preserve the official lifecycle-script policy'
  }
  Write-Output 'PASS valid unfinalized three-family staging and input verification'

  $closurePackages = @(
    [pscustomobject]@{
      Name = '@deepseek-ai/dsh'
      Manifest = [pscustomobject]@{
        dependencies = [pscustomobject]@{ '@deepseek-ai/dsh-required' = '^1.0.0' }
        peerDependencies = [pscustomobject]@{
          '@deepseek-ai/dsh-required-peer' = '^1.0.0'
          '@deepseek-ai/dsh-optional-peer' = '^1.0.0'
        }
        peerDependenciesMeta = [pscustomobject]@{
          '@deepseek-ai/dsh-optional-peer' = [pscustomobject]@{ optional = $true }
        }
      }
    },
    [pscustomobject]@{ Name = '@deepseek-ai/dsh-required'; Manifest = [pscustomobject]@{} },
    [pscustomobject]@{ Name = '@deepseek-ai/dsh-required-peer'; Manifest = [pscustomobject]@{} },
    [pscustomobject]@{ Name = '@deepseek-ai/dsh-optional-peer'; Manifest = [pscustomobject]@{} }
  )
  $closure = @(Get-DshInternalRuntimePackages -Packages $closurePackages)
  $closureNames = @($closure.Name | Sort-Object)
  if ($closureNames.Count -ne 3 -or '@deepseek-ai/dsh-optional-peer' -cin $closureNames -or
    '@deepseek-ai/dsh-required' -cnotin $closureNames -or '@deepseek-ai/dsh-required-peer' -cnotin $closureNames) {
    throw "runtime closure handled required and optional peers incorrectly: $($closureNames -join ', ')"
  }
  Write-Output 'PASS runtime closure includes required peers and excludes optional peers'

  $finalized = New-FinalizedTestInput -Baseline $baseline -Name 'finalized'
  $finalizedValid = Get-DshOfficialPackageInput `
    -Directory $finalized `
    -ExpectedVersion $version `
    -ExpectedSourceTag $sourceTag `
    -ExpectedSourceSha $sourceSha
  if ($finalizedValid.InternalRuntimePackages.Count -ne 1 -or
    $finalizedValid.ExternalRuntimeResolutions.Count -ne 50 -or
    -not $finalizedValid.ConsumerLockSha256) {
    throw 'valid finalized fixture returned inconsistent runtime metadata'
  }
  Write-Output 'PASS valid finalized consumer input verification'

  $tamperedConsumer = Copy-TestInput -Baseline $finalized -Name 'tampered-consumer'
  Add-Content -LiteralPath (Join-Path $tamperedConsumer 'consumer/pnpm-lock.yaml') -Value '# tampered'
  Assert-Throws -Name 'tampered consumer lock' -MessagePattern 'size or SHA256' -Action {
    Get-DshOfficialPackageInput -Directory $tamperedConsumer -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $tamperedControlHash = Copy-TestInput -Baseline $finalized -Name 'tampered-control-hash'
  $tamperedControlHashProvenance = Get-Content -LiteralPath (Join-Path $tamperedControlHash 'provenance.json') -Raw | ConvertFrom-Json
  $tamperedControlHashProvenance.consumerLockControlSha256 = '0' * 64
  Save-TestProvenance -InputDirectory $tamperedControlHash -Provenance $tamperedControlHashProvenance
  Assert-Throws -Name 'tampered consumer control hash' -MessagePattern 'control failed SHA256' -Action {
    Get-DshOfficialPackageInput -Directory $tamperedControlHash -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $redirectedImporter = Copy-TestInput -Baseline $finalized -Name 'redirected-root-importer'
  $redirectedImporterProvenance = Get-Content -LiteralPath (Join-Path $redirectedImporter 'provenance.json') -Raw | ConvertFrom-Json
  $redirectedImporterLock = Join-Path $redirectedImporter 'consumer/pnpm-lock.yaml'
  $redirectedImporterText = (Get-Content -LiteralPath $redirectedImporterLock -Raw).Replace('specifier: 4.4.3', 'specifier: 4.4.4')
  Set-Content -LiteralPath $redirectedImporterLock -Value $redirectedImporterText -Encoding utf8 -NoNewline
  Set-TestConsumerHashes -InputDirectory $redirectedImporter -Provenance $redirectedImporterProvenance
  Save-TestProvenance -InputDirectory $redirectedImporter -Provenance $redirectedImporterProvenance
  Assert-Throws -Name 'redirected consumer root importer' -MessagePattern 'differs from its verified control model' -Action {
    Get-DshOfficialPackageInput -Directory $redirectedImporter -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $unknownControlRoot = Copy-TestInput -Baseline $finalized -Name 'unknown-control-root'
  $unknownControlRootProvenance = Get-Content -LiteralPath (Join-Path $unknownControlRoot 'provenance.json') -Raw | ConvertFrom-Json
  $unknownControlRootLock = Join-Path $unknownControlRoot 'consumer/pnpm-lock.yaml'
  Add-Content -LiteralPath $unknownControlRootLock -Value 'catalogs:'
  Set-TestConsumerHashes -InputDirectory $unknownControlRoot -Provenance $unknownControlRootProvenance
  Save-TestProvenance -InputDirectory $unknownControlRoot -Provenance $unknownControlRootProvenance
  Assert-Throws -Name 'unknown consumer lock root field' -MessagePattern 'unsupported root field' -Action {
    Get-DshOfficialPackageInput -Directory $unknownControlRoot -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $extraConsumer = Copy-TestInput -Baseline $finalized -Name 'extra-consumer-file'
  Set-Content -LiteralPath (Join-Path $extraConsumer 'consumer/unlisted.txt') -Value 'unexpected' -Encoding utf8
  Assert-Throws -Name 'unlisted consumer file' -MessagePattern 'incomplete or unlisted consumer' -Action {
    Get-DshOfficialPackageInput -Directory $extraConsumer -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $extraDependency = Copy-TestInput -Baseline $finalized -Name 'extra-consumer-dependency'
  $extraDependencyProvenance = Get-Content -LiteralPath (Join-Path $extraDependency 'provenance.json') -Raw | ConvertFrom-Json
  $extraDependencyManifestPath = Join-Path $extraDependency 'consumer/package.json'
  $extraDependencyManifest = Get-Content -LiteralPath $extraDependencyManifestPath -Raw | ConvertFrom-Json
  $extraDependencyManifest.dependencies | Add-Member -NotePropertyName unexpected -NotePropertyValue '1.0.0'
  $extraDependencyManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $extraDependencyManifestPath -Encoding utf8
  Set-TestConsumerHashes -InputDirectory $extraDependency -Provenance $extraDependencyProvenance
  Save-TestProvenance -InputDirectory $extraDependency -Provenance $extraDependencyProvenance
  Assert-Throws -Name 'extra consumer dependency' -MessagePattern 'dependencies, expected' -Action {
    Get-DshOfficialPackageInput -Directory $extraDependency -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $tamperedMapHash = Copy-TestInput -Baseline $finalized -Name 'tampered-map-hash'
  $tamperedMapHashProvenance = Get-Content -LiteralPath (Join-Path $tamperedMapHash 'provenance.json') -Raw | ConvertFrom-Json
  $tamperedMapHashProvenance.runtimeResolutionsSha256 = '0' * 64
  Save-TestProvenance -InputDirectory $tamperedMapHash -Provenance $tamperedMapHashProvenance
  Assert-Throws -Name 'tampered runtime map hash' -MessagePattern 'map failed SHA256' -Action {
    Get-DshOfficialPackageInput -Directory $tamperedMapHash -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $tamperedInternalEdge = Copy-TestInput -Baseline $finalized -Name 'tampered-internal-edge'
  $tamperedInternalEdgeProvenance = Get-Content -LiteralPath (Join-Path $tamperedInternalEdge 'provenance.json') -Raw | ConvertFrom-Json
  $tamperedInternalEdgeProvenance.internalRuntimeSnapshots[0].snapshot.dependencies.'fixture-package-00' = '2.0.0'
  Save-TestProvenance -InputDirectory $tamperedInternalEdge -Provenance $tamperedInternalEdgeProvenance
  Assert-Throws -Name 'tampered internal snapshot edge' -MessagePattern 'internal runtime snapshot map failed SHA256' -Action {
    Get-DshOfficialPackageInput -Directory $tamperedInternalEdge -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $unsupportedSnapshot = Copy-TestInput -Baseline $finalized -Name 'unsupported-snapshot-field'
  $unsupportedSnapshotProvenance = Get-Content -LiteralPath (Join-Path $unsupportedSnapshot 'provenance.json') -Raw | ConvertFrom-Json
  $unsupportedSnapshotProvenance.runtimeResolutions[0].snapshot | Add-Member -NotePropertyName devDependencies -NotePropertyValue ([pscustomobject]@{})
  $unsupportedSnapshotProvenance.runtimeResolutionsSha256 = Get-DshRuntimeResolutionsSha256 -Records @($unsupportedSnapshotProvenance.runtimeResolutions)
  Save-TestProvenance -InputDirectory $unsupportedSnapshot -Provenance $unsupportedSnapshotProvenance
  Assert-Throws -Name 'unsupported runtime snapshot field' -MessagePattern 'unsupported field' -Action {
    Get-DshOfficialPackageInput -Directory $unsupportedSnapshot -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $unsupportedPackage = Copy-TestInput -Baseline $finalized -Name 'unsupported-package-field'
  $unsupportedPackageProvenance = Get-Content -LiteralPath (Join-Path $unsupportedPackage 'provenance.json') -Raw | ConvertFrom-Json
  $unsupportedPackageProvenance.runtimeResolutions[0].package | Add-Member -NotePropertyName scripts -NotePropertyValue ([pscustomobject]@{})
  $unsupportedPackageProvenance.runtimeResolutionsSha256 = Get-DshRuntimeResolutionsSha256 -Records @($unsupportedPackageProvenance.runtimeResolutions)
  Save-TestProvenance -InputDirectory $unsupportedPackage -Provenance $unsupportedPackageProvenance
  Assert-Throws -Name 'unsupported runtime package field' -MessagePattern 'unsupported field scripts' -Action {
    Get-DshOfficialPackageInput -Directory $unsupportedPackage -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $missingInternalPackage = Copy-TestInput -Baseline $finalized -Name 'missing-internal-package-body'
  $missingInternalPackageProvenance = Get-Content -LiteralPath (Join-Path $missingInternalPackage 'provenance.json') -Raw | ConvertFrom-Json
  $missingInternalPackageProvenance.internalRuntimeSnapshots[0].PSObject.Properties.Remove('package')
  $missingInternalPackageProvenance.internalRuntimeSnapshotsSha256 = Get-DshCanonicalRecordsSha256 -Records @($missingInternalPackageProvenance.internalRuntimeSnapshots)
  Save-TestProvenance -InputDirectory $missingInternalPackage -Provenance $missingInternalPackageProvenance
  Assert-Throws -Name 'missing internal runtime package body' -MessagePattern 'unsupported record fields|no package body' -Action {
    Get-DshOfficialPackageInput -Directory $missingInternalPackage -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $invalidMapIdentity = Copy-TestInput -Baseline $finalized -Name 'invalid-map-identity'
  $invalidMapIdentityProvenance = Get-Content -LiteralPath (Join-Path $invalidMapIdentity 'provenance.json') -Raw | ConvertFrom-Json
  $invalidMapIdentityProvenance.runtimeResolutions[0].packageName = 'different-package'
  $invalidMapIdentityProvenance.runtimeResolutionsSha256 = Get-DshRuntimeResolutionsSha256 -Records @($invalidMapIdentityProvenance.runtimeResolutions)
  Save-TestProvenance -InputDirectory $invalidMapIdentity -Provenance $invalidMapIdentityProvenance
  Assert-Throws -Name 'inconsistent runtime map identity' -MessagePattern 'inconsistent package keys' -Action {
    Get-DshOfficialPackageInput -Directory $invalidMapIdentity -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $dualResolution = Copy-TestInput -Baseline $finalized -Name 'dual-resolution'
  $dualResolutionProvenance = Get-Content -LiteralPath (Join-Path $dualResolution 'provenance.json') -Raw | ConvertFrom-Json
  $dualResolutionProvenance.runtimeResolutions[0].resolution | Add-Member `
    -NotePropertyName tarball `
    -NotePropertyValue 'https://registry.npmjs.org/fixture-package-00/-/fixture-package-00-1.0.0.tgz'
  $dualResolutionProvenance.runtimeResolutionsSha256 = Get-DshRuntimeResolutionsSha256 -Records @($dualResolutionProvenance.runtimeResolutions)
  Save-TestProvenance -InputDirectory $dualResolution -Provenance $dualResolutionProvenance
  [void](Get-DshOfficialPackageInput -Directory $dualResolution -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha)
  Write-Output 'PASS dual-field external resolution'

  $extraInternal = Copy-TestInput -Baseline $finalized -Name 'extra-internal-runtime-record'
  $extraInternalProvenance = Get-Content -LiteralPath (Join-Path $extraInternal 'provenance.json') -Raw | ConvertFrom-Json
  $extraInternalProvenance.runtimeInternalPackages = @($extraInternalProvenance.runtimeInternalPackages) + $extraInternalProvenance.runtimeInternalPackages[0]
  $extraInternalProvenance.runtimeInternalPackageCount = 2
  Save-TestProvenance -InputDirectory $extraInternal -Provenance $extraInternalProvenance
  Assert-Throws -Name 'extra internal runtime record' -MessagePattern 'inconsistent internal runtime package count' -Action {
    Get-DshOfficialPackageInput -Directory $extraInternal -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha
  }

  $tamperedLock = Copy-TestInput -Baseline $baseline -Name 'tampered-lock'
  Add-Content -LiteralPath (Join-Path $tamperedLock 'runtime-lock/pnpm-lock.yaml') -Value '# tampered'
  Assert-Throws -Name 'tampered official runtime lock' -MessagePattern 'size or SHA256' -Action {
    Get-DshOfficialPackageInput -Directory $tamperedLock -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha -AllowUnfinalized
  }

  $duplicateLockRecord = Copy-TestInput -Baseline $baseline -Name 'duplicate-lock-record'
  $duplicateLockProvenance = Get-Content -LiteralPath (Join-Path $duplicateLockRecord 'provenance.json') -Raw | ConvertFrom-Json
  $packageRecord = @($duplicateLockProvenance.runtimeLockFiles | Where-Object { $_.relativePath -ceq 'package.json' })[0]
  $lockRecordIndex = 0
  for ($index = 0; $index -lt $duplicateLockProvenance.runtimeLockFiles.Count; $index++) {
    if ($duplicateLockProvenance.runtimeLockFiles[$index].relativePath -ceq 'pnpm-lock.yaml') { $lockRecordIndex = $index; break }
  }
  $duplicateLockProvenance.runtimeLockFiles[$lockRecordIndex] = [pscustomobject][ordered]@{
    relativePath = [string]$packageRecord.relativePath
    size = [int64]$packageRecord.size
    sha256 = [string]$packageRecord.sha256
  }
  Add-Content -LiteralPath (Join-Path $duplicateLockRecord 'runtime-lock/pnpm-lock.yaml') -Value '# unlisted tamper'
  Save-TestProvenance -InputDirectory $duplicateLockRecord -Provenance $duplicateLockProvenance
  Assert-Throws -Name 'duplicate runtime lock record' -MessagePattern 'duplicates file' -Action {
    Get-DshOfficialPackageInput -Directory $duplicateLockRecord -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha -AllowUnfinalized
  }

  $missingPolicy = Copy-TestInput -Baseline $baseline -Name 'missing-policy'
  $missingPolicyProvenance = Get-Content -LiteralPath (Join-Path $missingPolicy 'provenance.json') -Raw | ConvertFrom-Json
  $missingPolicyProvenance.PSObject.Properties.Remove('allowBuilds')
  Save-TestProvenance -InputDirectory $missingPolicy -Provenance $missingPolicyProvenance
  Assert-Throws -Name 'missing lifecycle-script policy' -MessagePattern 'no allowBuilds policy' -Action {
    Get-DshOfficialPackageInput -Directory $missingPolicy -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha -AllowUnfinalized
  }

  $invalidPolicy = Copy-TestInput -Baseline $baseline -Name 'invalid-policy'
  $invalidPolicyProvenance = Get-Content -LiteralPath (Join-Path $invalidPolicy 'provenance.json') -Raw | ConvertFrom-Json
  $invalidPolicyProvenance.allowBuilds.protobufjs = 'false'
  Save-TestProvenance -InputDirectory $invalidPolicy -Provenance $invalidPolicyProvenance
  Assert-Throws -Name 'non-boolean lifecycle-script policy' -MessagePattern 'invalid allowBuilds entry' -Action {
    Get-DshOfficialPackageInput -Directory $invalidPolicy -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha -AllowUnfinalized
  }

  $tampered = Copy-TestInput -Baseline $baseline -Name 'tampered'
  [IO.File]::AppendAllText((Join-Path $tampered 'vendor/deepseek-ai-cordis.tgz'), 'tamper')
  Assert-Throws -Name 'tampered archive hash' -MessagePattern 'size or SHA256' -Action {
    Get-DshOfficialPackageInput -Directory $tampered -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha -AllowUnfinalized
  }

  $extra = Copy-TestInput -Baseline $baseline -Name 'extra'
  Copy-Item -LiteralPath (Join-Path $extra 'vendor/deepseek-ai-cordis.tgz') -Destination (Join-Path $extra 'vendor/unlisted.tgz')
  Assert-Throws -Name 'unlisted extra archive' -MessagePattern 'missing or unlisted archives' -Action {
    Get-DshOfficialPackageInput -Directory $extra -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha -AllowUnfinalized
  }

  $duplicate = Copy-TestInput -Baseline $baseline -Name 'duplicate'
  $duplicateArchive = Join-Path $duplicate 'dsh/duplicate-dsh.tgz'
  Copy-Item -LiteralPath (Join-Path $duplicate 'dsh/deepseek-ai-dsh.tgz') -Destination $duplicateArchive
  $duplicateProvenance = Get-Content -LiteralPath (Join-Path $duplicate 'provenance.json') -Raw | ConvertFrom-Json
  $duplicateRecord = [pscustomobject][ordered]@{
    relativePath = 'dsh/duplicate-dsh.tgz'
    name = '@deepseek-ai/dsh'
    version = $version
    size = (Get-Item -LiteralPath $duplicateArchive).Length
    sha256 = (Get-FileHash -LiteralPath $duplicateArchive -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  $duplicateProvenance.packages = @($duplicateProvenance.packages) + $duplicateRecord
  Save-TestProvenance -InputDirectory $duplicate -Provenance $duplicateProvenance
  Assert-Throws -Name 'duplicate package identity' -MessagePattern 'name is duplicated' -Action {
    Get-DshOfficialPackageInput -Directory $duplicate -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha -AllowUnfinalized
  }

  $workspace = Copy-TestInput -Baseline $baseline -Name 'workspace'
  $workspaceArchive = Join-Path $workspace 'vendor/deepseek-ai-cordis.tgz'
  New-TestArchive -ArchivePath $workspaceArchive -Name '@deepseek-ai/cordis' -Version '4.0.1' -Dependencies @{ invalid = 'workspace:*' }
  $workspaceProvenance = Get-Content -LiteralPath (Join-Path $workspace 'provenance.json') -Raw | ConvertFrom-Json
  $workspaceRecord = @($workspaceProvenance.packages | Where-Object { $_.relativePath -ceq 'vendor/deepseek-ai-cordis.tgz' })
  if ($workspaceRecord.Count -ne 1) { throw 'workspace fixture record missing' }
  $workspaceRecord[0].size = (Get-Item -LiteralPath $workspaceArchive).Length
  $workspaceRecord[0].sha256 = (Get-FileHash -LiteralPath $workspaceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
  Save-TestProvenance -InputDirectory $workspace -Provenance $workspaceProvenance
  Assert-Throws -Name 'workspace dependency residue' -MessagePattern 'retains a workspace dependency' -Action {
    Get-DshOfficialPackageInput -Directory $workspace -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha -AllowUnfinalized
  }

  Assert-Throws -Name 'DSH version mismatch' -MessagePattern 'dsh version' -Action {
    Get-DshOfficialPackageInput -Directory $baseline -ExpectedVersion '0.1.2-alpha.2' -ExpectedSourceTag $sourceTag -ExpectedSourceSha $sourceSha -AllowUnfinalized
  }
  Assert-Throws -Name 'source tag mismatch' -MessagePattern 'source tag' -Action {
    Get-DshOfficialPackageInput -Directory $baseline -ExpectedVersion $version -ExpectedSourceTag 'dsh-v0.1.2-alpha.2' -ExpectedSourceSha $sourceSha -AllowUnfinalized
  }
  Assert-Throws -Name 'source SHA mismatch' -MessagePattern 'source SHA' -Action {
    Get-DshOfficialPackageInput -Directory $baseline -ExpectedVersion $version -ExpectedSourceTag $sourceTag -ExpectedSourceSha ('d' * 40) -AllowUnfinalized
  }

  Add-Content -LiteralPath (Join-Path $source 'package.json') -Value ' '
  Assert-Throws -Name 'tracked official source mutation' -MessagePattern 'changed tracked source files' -Action {
    & $stageScript `
      -SourceDirectory $source `
      -OutputDirectory (Join-Path $testRoot 'dirty-output') `
      -ExpectedVersion $version `
      -ExpectedSourceTag $sourceTag `
      -ExpectedSourceSha $sourceSha
  }

  Write-Output 'PASS all official package input tests'
} finally {
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\', [char]'/')
  $resolvedTest = [IO.Path]::GetFullPath($testRoot)
  if (-not $resolvedTest.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) `
    -or (Split-Path $resolvedTest -Leaf) -cnotlike 'dsh-official-package-input-*') {
    throw "refusing to clean unexpected test directory: $resolvedTest"
  }
  if (Test-Path -LiteralPath $resolvedTest) { Remove-Item -LiteralPath $resolvedTest -Recurse -Force }
}
