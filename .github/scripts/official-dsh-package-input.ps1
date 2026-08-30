# Helpers for staging and validating the package set produced by the official
# DeepSeek Harness release scripts. This file performs no network operations.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'pnpm-lock-policy.ps1')

function Read-DshOfficialAllowBuildsPolicy {
  param([Parameter(Mandatory)][string]$WorkspacePath)

  if (-not (Test-Path -LiteralPath $WorkspacePath -PathType Leaf)) {
    throw "official source has no pnpm workspace policy: $WorkspacePath"
  }
  $inside = $false
  $found = $false
  $policy = [ordered]@{}
  foreach ($line in @(Get-Content -LiteralPath $WorkspacePath)) {
    if (-not $inside) {
      if ($line -cmatch '^allowBuilds:\s*(?:#.*)?$') {
        $inside = $true
        $found = $true
      }
      continue
    }
    if ($line -cmatch '^\S') { break }
    if ($line -cmatch '^\s*$' -or $line -cmatch '^\s*#') { continue }
    $match = [regex]::Match($line, '^\s{2}(?<name>''(?:[^'']|'''')+''|"(?:[^"\\]|\\.)+"|[A-Za-z0-9@/._-]+):\s*(?<enabled>true|false)\s*(?:#.*)?$')
    if (-not $match.Success) { throw "unsupported allowBuilds entry in official source: $line" }
    $encodedName = [string]$match.Groups['name'].Value
    if ($encodedName.StartsWith("'")) {
      $name = $encodedName.Substring(1, $encodedName.Length - 2).Replace("''", "'")
    } elseif ($encodedName.StartsWith('"')) {
      $name = [string]($encodedName | ConvertFrom-Json)
    } else {
      $name = $encodedName
    }
    if ($name -cnotmatch '^(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*(?:@file:[^\r\n]+)?$') {
      throw "unsupported allowBuilds package selector in official source: $name"
    }
    if ($policy.Contains($name)) { throw "duplicate allowBuilds package selector in official source: $name" }
    $policy[$name] = $match.Groups['enabled'].Value -ceq 'true'
  }
  if (-not $found -or $policy.Count -eq 0) { throw 'official source has no allowBuilds policy entries' }
  if (@($policy.Values | Where-Object { $_ -eq $true }).Count -eq 0 -or
    @($policy.Values | Where-Object { $_ -eq $false }).Count -eq 0) {
    throw 'official allowBuilds policy must explicitly contain permitted and denied scripts'
  }
  return $policy
}

function ConvertTo-DshVerifiedAllowBuildsPolicy {
  param([Parameter(Mandatory)][object]$Value)

  if ($null -eq $Value) { throw 'official package provenance has no allowBuilds policy' }
  $policy = [ordered]@{}
  foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
    $name = [string]$property.Name
    if ($name -cnotmatch '^(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*(?:@file:[^\r\n]+)?$' -or
      $property.Value -isnot [bool]) {
      throw "official package provenance has an invalid allowBuilds entry: $name"
    }
    if ($policy.Contains($name)) { throw "official package provenance duplicates allowBuilds entry: $name" }
    $policy[$name] = [bool]$property.Value
  }
  if ($policy.Count -eq 0 -or
    @($policy.Values | Where-Object { $_ -eq $true }).Count -eq 0 -or
    @($policy.Values | Where-Object { $_ -eq $false }).Count -eq 0) {
    throw 'official package provenance has an incomplete allowBuilds policy'
  }
  return $policy
}

function Read-DshOfficialPatchedDependencies {
  param([Parameter(Mandatory)][string]$WorkspacePath)

  $inside = $false
  $found = $false
  $patches = [ordered]@{}
  foreach ($line in @(Get-Content -LiteralPath $WorkspacePath)) {
    if (-not $inside) {
      if ($line -cmatch '^patchedDependencies:\s*(?:#.*)?$') {
        $inside = $true
        $found = $true
      }
      continue
    }
    if ($line -cmatch '^\S') { break }
    if ($line -cmatch '^\s*$' -or $line -cmatch '^\s*#') { continue }
    $match = [regex]::Match($line, '^\s{2}(?<name>''(?:[^'']|'''')+''|"(?:[^"\\]|\\.)+"|[A-Za-z0-9@/._-]+):\s*(?<path>patches/[A-Za-z0-9@._-]+\.patch)\s*(?:#.*)?$')
    if (-not $match.Success) { throw "unsupported patchedDependencies entry in official source: $line" }
    $encodedName = [string]$match.Groups['name'].Value
    if ($encodedName.StartsWith("'")) {
      $name = $encodedName.Substring(1, $encodedName.Length - 2).Replace("''", "'")
    } elseif ($encodedName.StartsWith('"')) {
      $name = [string]($encodedName | ConvertFrom-Json)
    } else {
      $name = $encodedName
    }
    $relativePath = [string]$match.Groups['path'].Value
    if ($patches.Contains($name)) { throw "duplicate patchedDependencies selector in official source: $name" }
    $patches[$name] = $relativePath
  }
  if (-not $found) { return [ordered]@{} }
  return $patches
}

function ConvertTo-DshVerifiedPatchedDependencies {
  param([Parameter(Mandatory)][object]$Value)

  $patches = [ordered]@{}
  if ($null -eq $Value) { return $patches }
  foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
    $name = [string]$property.Name
    $relativePath = [string]$property.Value
    if (-not $name -or $relativePath -cnotmatch '^patches/[A-Za-z0-9@._-]+\.patch$') {
      throw "official package provenance has an invalid patchedDependencies entry: $name"
    }
    $patches[$name] = $relativePath
  }
  return $patches
}

function Read-DshPackedPackageIdentity {
  param([Parameter(Mandatory)][string]$ArchivePath)

  if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "package archive is missing: $ArchivePath"
  }
  $jsonLines = @(& tar -xOf $ArchivePath 'package/package.json')
  if ($LASTEXITCODE -ne 0 -or $jsonLines.Count -eq 0) {
    throw "cannot read package/package.json from $ArchivePath"
  }
  $raw = $jsonLines -join "`n"
  if ($raw -match '(?i)(?:^|[\"''\s])workspace:') {
    throw "packed package retains a workspace dependency: $ArchivePath"
  }
  $manifest = $raw | ConvertFrom-Json
  $name = [string]$manifest.name
  $version = [string]$manifest.version
  if ($name -cnotmatch '^@deepseek-ai/[a-z0-9][a-z0-9._-]*$') {
    throw "packed package has an unexpected name: $name"
  }
  if (-not $version -or $version.Contains('/') -or $version.Contains('\')) {
    throw "packed package $name has an invalid version: $version"
  }
  return [pscustomobject]@{
    Manifest = $manifest
    Name = $name
    Version = $version
  }
}

function Get-DshPackageRelativePath {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Path
  )

  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char]'\', [char]'/')
  $pathFull = [IO.Path]::GetFullPath($Path)
  $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
  if (-not $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "package path leaves its declared root: $Path"
  }
  return $pathFull.Substring($prefix.Length).Replace('\', '/')
}

function Get-DshInternalRuntimePackages {
  param([Parameter(Mandatory)][object[]]$Packages)

  $byName = @{}
  foreach ($package in $Packages) {
    $name = [string]$package.Name
    if ($byName.ContainsKey($name)) { throw "official package input duplicates $name" }
    $byName[$name] = $package
  }
  $entryName = '@deepseek-ai/dsh'
  if (-not $byName.ContainsKey($entryName)) { throw 'official package input has no dsh runtime root' }
  $selected = @{}
  $queue = [Collections.Generic.Queue[string]]::new()
  $queue.Enqueue($entryName)
  while ($queue.Count -gt 0) {
    $name = $queue.Dequeue()
    if ($selected.ContainsKey($name)) { continue }
    $package = $byName[$name]
    $selected[$name] = $package
    $manifest = $package.Manifest
    foreach ($field in @('dependencies', 'optionalDependencies', 'peerDependencies')) {
      $property = $manifest.PSObject.Properties[$field]
      if ($null -eq $property -or $null -eq $property.Value) { continue }
      foreach ($dependency in @($property.Value.PSObject.Properties)) {
        $dependencyName = [string]$dependency.Name
        $isOptionalPeer = $false
        if ($field -ceq 'peerDependencies') {
          $peerMetaProperty = $manifest.PSObject.Properties['peerDependenciesMeta']
          if ($null -ne $peerMetaProperty -and $null -ne $peerMetaProperty.Value) {
            $dependencyMeta = $peerMetaProperty.Value.PSObject.Properties[$dependencyName]
            $isOptionalPeer = $null -ne $dependencyMeta -and [bool]$dependencyMeta.Value.optional
          }
        }
        if ($isOptionalPeer) { continue }
        if (-not $dependencyName.StartsWith('@deepseek-ai/', [StringComparison]::Ordinal)) { continue }
        if ($byName.ContainsKey($dependencyName)) {
          if (-not $selected.ContainsKey($dependencyName)) { $queue.Enqueue($dependencyName) }
          continue
        }
        $isOptional = $field -ceq 'optionalDependencies'
        if (-not $isOptional) { throw "official runtime dependency $dependencyName required by $name is absent from the package input" }
      }
    }
  }
  return @($selected.Values | Sort-Object Name)
}

function ConvertTo-DshCanonicalJsonValue {
  param([Parameter(Mandatory)]$Value)

  if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $Value }
  if ($Value -is [Collections.IDictionary]) {
    $keys = @($Value.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $result = [ordered]@{}
    foreach ($key in $keys) { $result[$key] = ConvertTo-DshCanonicalJsonValue -Value $Value[$key] }
    return $result
  }
  if ($Value -is [Collections.IEnumerable]) {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($item in $Value) { $items.Add((ConvertTo-DshCanonicalJsonValue -Value $item)) }
    return ,$items.ToArray()
  }
  $properties = @($Value.PSObject.Properties)
  if ($properties.Count -eq 0) {
    if ($Value -is [pscustomobject]) { return [ordered]@{} }
    throw "cannot canonicalize unsupported JSON value: $($Value.GetType().FullName)"
  }
  $names = @($properties | ForEach-Object { [string]$_.Name })
  [Array]::Sort($names, [StringComparer]::Ordinal)
  $object = [ordered]@{}
  foreach ($name in $names) {
    $object[$name] = ConvertTo-DshCanonicalJsonValue -Value $Value.PSObject.Properties[$name].Value
  }
  return $object
}

function Get-DshCanonicalValueSha256 {
  param([Parameter(Mandatory)]$Value)

  $canonical = ConvertTo-DshCanonicalJsonValue -Value $Value
  $json = ConvertTo-Json -InputObject $canonical -Depth 20 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    return ([Convert]::ToHexString($hasher.ComputeHash($bytes))).ToLowerInvariant()
  } finally {
    $hasher.Dispose()
  }
}

function Get-DshCanonicalRecordsSha256 {
  param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Records)

  return Get-DshCanonicalValueSha256 -Value @($Records)
}

function Get-DshRuntimeResolutionsSha256 {
  param([Parameter(Mandatory)][object[]]$Records)

  return Get-DshCanonicalRecordsSha256 -Records $Records
}

function ConvertTo-DshVerifiedRuntimeSnapshot {
  param(
    [Parameter(Mandatory)][object]$Value,
    [Parameter(Mandatory)][string]$Description
  )

  return (ConvertTo-DshPnpmSnapshotBody -Snapshot $Value -Description $Description).Value
}

function ConvertTo-DshVerifiedRuntimePackage {
  param(
    [Parameter(Mandatory)][object]$Value,
    [Parameter(Mandatory)][string]$Description
  )

  return (ConvertTo-DshPnpmPackageBody -Package $Value -Description $Description).Value
}

function Get-DshOfficialPackageInput {
  param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][string]$ExpectedVersion,
    [Parameter(Mandatory)][string]$ExpectedSourceTag,
    [Parameter(Mandatory)][string]$ExpectedSourceSha,
    [switch]$AllowUnfinalized
  )

  $rootItem = Get-Item -LiteralPath $Directory -ErrorAction Stop
  if (-not $rootItem.PSIsContainer) { throw "official package input is not a directory: $Directory" }
  $root = $rootItem.FullName.TrimEnd([char]'\', [char]'/')
  $provenancePath = Join-Path $root 'provenance.json'
  $sumsPath = Join-Path $root 'SHA256SUMS.txt'
  if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) { throw 'official package input has no provenance.json' }
  if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) { throw 'official package input has no SHA256SUMS.txt' }

  $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
  $schemaVersion = [int]$provenance.schemaVersion
  if (($schemaVersion -ne 4 -and -not ($AllowUnfinalized -and $schemaVersion -eq 3)) -or
    [string]$provenance.kind -cne 'official-git-tag') {
    throw 'official package provenance uses an unsupported format'
  }
  if ([string]$provenance.repository -cne 'https://github.com/deepseek-ai/deepseek-harness') {
    throw "unexpected official source repository: $($provenance.repository)"
  }
  if ([string]$provenance.dshVersion -cne $ExpectedVersion) {
    throw "official package dsh version $($provenance.dshVersion) != $ExpectedVersion"
  }
  if ([string]$provenance.sourceTag -cne $ExpectedSourceTag) {
    throw "official package source tag $($provenance.sourceTag) != $ExpectedSourceTag"
  }
  if ([string]$provenance.sourceSha -cne $ExpectedSourceSha.ToLowerInvariant()) {
    throw "official package source SHA $($provenance.sourceSha) != $ExpectedSourceSha"
  }
  if ([string]$provenance.packageManager -cnotmatch '^pnpm@(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
    throw "official package provenance has an invalid package manager: $($provenance.packageManager)"
  }
  $allowBuildsProperty = $provenance.PSObject.Properties['allowBuilds']
  if ($null -eq $allowBuildsProperty) { throw 'official package provenance has no allowBuilds policy' }
  $allowBuilds = ConvertTo-DshVerifiedAllowBuildsPolicy -Value $allowBuildsProperty.Value
  $patchedDependenciesProperty = $provenance.PSObject.Properties['patchedDependencies']
  $patchedDependencies = ConvertTo-DshVerifiedPatchedDependencies -Value $(
    if ($null -eq $patchedDependenciesProperty) { $null } else { $patchedDependenciesProperty.Value }
  )

  $runtimeFilesProperty = $provenance.PSObject.Properties['runtimeLockFiles']
  if ($null -eq $runtimeFilesProperty) { throw 'official package provenance has no runtime lock files' }
  $runtimeRecords = @($runtimeFilesProperty.Value | ForEach-Object { $_ })
  if ($runtimeRecords.Count -lt 3) { throw 'official package provenance has an incomplete runtime lock file set' }
  $runtimeRoot = Join-Path $root 'runtime-lock'
  $runtimeFiles = @(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File -ErrorAction Stop | Sort-Object FullName)
  if ($runtimeFiles.Count -ne $runtimeRecords.Count) { throw 'official runtime lock directory has missing or unlisted files' }
  $runtimePaths = @{}
  foreach ($file in $runtimeFiles) {
    $relative = Get-DshPackageRelativePath -Root $runtimeRoot -Path $file.FullName
    if ($relative -cnotmatch '^(?:package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|patches/[A-Za-z0-9@._-]+\.patch)$') {
      throw "official runtime lock has an unexpected file: $relative"
    }
    $runtimePaths[$relative] = $file.FullName
  }
  $runtimeSeen = @{}
  foreach ($record in $runtimeRecords) {
    $relative = [string]$record.relativePath
    if ($runtimeSeen.ContainsKey($relative)) { throw "official runtime lock provenance duplicates file: $relative" }
    $runtimeSeen[$relative] = $true
    if (-not $runtimePaths.ContainsKey($relative)) { throw "official runtime lock provenance names a missing file: $relative" }
    $file = [string]$runtimePaths[$relative]
    $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ((Get-Item -LiteralPath $file).Length -ne [int64]$record.size -or $sha -cne [string]$record.sha256) {
      throw "official runtime lock file failed size or SHA256 verification: $relative"
    }
  }
  foreach ($required in @('package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml')) {
    if (-not $runtimePaths.ContainsKey($required) -or -not $runtimeSeen.ContainsKey($required)) {
      throw "official runtime lock is missing $required"
    }
  }
  foreach ($patchPath in $patchedDependencies.Values) {
    if (-not $runtimePaths.ContainsKey([string]$patchPath)) { throw "official runtime lock is missing patch $patchPath" }
  }

  $records = @($provenance.packages | ForEach-Object { $_ })
  if ($records.Count -ne [int]$provenance.packageCount -or $records.Count -lt 3) {
    throw 'official package provenance has an inconsistent package count'
  }
  $sumLines = @(Get-Content -LiteralPath $sumsPath | Where-Object { $_.Trim() })
  if ($sumLines.Count -ne $records.Count) { throw 'official package checksum count does not match provenance' }
  $sumMap = @{}
  foreach ($line in $sumLines) {
    $match = [regex]::Match([string]$line, '^(?<hash>[0-9a-f]{64})  (?<path>(?:dsh|vendor|landlock)/[^/]+\.tgz)$')
    if (-not $match.Success) { throw "invalid official package checksum line: $line" }
    $relative = [string]$match.Groups['path'].Value
    if ($sumMap.ContainsKey($relative)) { throw "duplicate checksum path: $relative" }
    $sumMap[$relative] = [string]$match.Groups['hash'].Value
  }

  $actualFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.tgz' | Sort-Object FullName)
  if ($actualFiles.Count -ne $records.Count) { throw 'official package directory has missing or unlisted archives' }
  $actualPaths = @{}
  foreach ($file in $actualFiles) {
    $relative = Get-DshPackageRelativePath -Root $root -Path $file.FullName
    if ($relative -cnotmatch '^(?:dsh|vendor|landlock)/[^/]+\.tgz$') {
      throw "official package archive is outside an allowed family directory: $relative"
    }
    $actualPaths[$relative] = $file.FullName
  }

  $names = @{}
  $verified = @()
  $entryCount = 0
  $familyCounts = @{ dsh = 0; vendor = 0; landlock = 0 }
  foreach ($record in @($records | Sort-Object relativePath)) {
    $relative = [string]$record.relativePath
    $relativeMatch = [regex]::Match($relative, '^(?<family>dsh|vendor|landlock)/[^/]+\.tgz$')
    if (-not $relativeMatch.Success -or -not $actualPaths.ContainsKey($relative)) {
      throw "official package provenance names a missing or invalid archive: $relative"
    }
    if (-not $sumMap.ContainsKey($relative)) { throw "official package has no checksum: $relative" }
    $archive = [string]$actualPaths[$relative]
    $size = (Get-Item -LiteralPath $archive).Length
    $sha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($size -ne [int64]$record.size -or $sha -cne [string]$record.sha256 -or $sha -cne [string]$sumMap[$relative]) {
      throw "official package archive failed size or SHA256 verification: $relative"
    }
    $identity = Read-DshPackedPackageIdentity -ArchivePath $archive
    if ($identity.Name -cne [string]$record.name -or $identity.Version -cne [string]$record.version) {
      throw "official package identity differs from provenance: $relative"
    }
    if ($names.ContainsKey($identity.Name)) { throw "official package name is duplicated: $($identity.Name)" }
    $names[$identity.Name] = $true
    $family = [string]$relativeMatch.Groups['family'].Value
    $familyCounts[$family]++
    if ($family -ceq 'dsh' -and $identity.Version -cne $ExpectedVersion) {
      throw "dsh family package $($identity.Name) has version $($identity.Version), expected $ExpectedVersion"
    }
    if ($identity.Name -ceq '@deepseek-ai/dsh') { $entryCount++ }
    $verified += [pscustomobject]@{
      File = $archive
      Manifest = $identity.Manifest
      Name = $identity.Name
      RelativePath = $relative
      Sha256 = $sha
      Size = $size
      Version = $identity.Version
    }
  }
  if ($entryCount -ne 1) { throw 'official package input must contain exactly one @deepseek-ai/dsh archive' }
  foreach ($family in @('dsh', 'vendor', 'landlock')) {
    if ($familyCounts[$family] -le 0) { throw "official package input has no $family archives" }
  }
  $internalRuntimePackages = @(Get-DshInternalRuntimePackages -Packages $verified)
  $consumerRoot = $null
  $consumerFiles = @()
  $consumerLockControl = $null
  $consumerLockControlSha256 = ''
  $consumerLockSha256 = ''
  $internalRuntimeSnapshots = @()
  $internalRuntimeSnapshotsSha256 = ''
  $runtimeResolutions = @()
  $runtimeResolutionsSha256 = ''
  if ($schemaVersion -eq 4) {
    if ([string]$provenance.target -cne 'win32-x64') {
      throw "official package provenance targets an unsupported platform: $($provenance.target)"
    }
    if ([string]$provenance.runtimeGraphDerivation -cne 'official-lock-importers-prod-optional-required-peers') {
      throw 'official package provenance uses an unsupported runtime graph derivation'
    }
    $internalRecords = @($provenance.runtimeInternalPackages | ForEach-Object { $_ })
    if ($internalRecords.Count -ne [int]$provenance.runtimeInternalPackageCount -or
      $internalRecords.Count -ne $internalRuntimePackages.Count) {
      throw 'official package provenance has an inconsistent internal runtime package count'
    }
    $internalByName = @{}
    foreach ($record in $internalRecords) {
      $name = [string]$record.name
      if ($internalByName.ContainsKey($name)) { throw "official runtime package provenance duplicates $name" }
      $internalByName[$name] = $record
    }
    foreach ($package in $internalRuntimePackages) {
      $record = $internalByName[[string]$package.Name]
      if ($null -eq $record -or
        [string]$record.version -cne [string]$package.Version -or
        [string]$record.relativePath -cne [string]$package.RelativePath -or
        [string]$record.sha256 -cne [string]$package.Sha256) {
        throw "official runtime package set differs from the verified archive closure: $($package.Name)"
      }
    }

    $runtimeResolutions = @($provenance.runtimeResolutions | ForEach-Object { $_ })
    if ($runtimeResolutions.Count -ne [int]$provenance.externalResolutionCount -or $runtimeResolutions.Count -lt 50) {
      throw 'official package provenance has an inconsistent external runtime resolution count'
    }
    $seenSnapshots = @{}
    foreach ($record in $runtimeResolutions) {
      $recordFields = @($record.PSObject.Properties.Name)
      $expectedRecordFields = @('package', 'packageKey', 'packageName', 'packageVersion', 'resolution', 'snapshot', 'snapshotKey')
      if ($recordFields.Count -ne $expectedRecordFields.Count -or
        @($recordFields | Where-Object { $_ -cnotin $expectedRecordFields }).Count -gt 0) {
        throw 'official runtime resolution has unsupported record fields'
      }
      $snapshotKey = [string]$record.snapshotKey
      $packageKey = [string]$record.packageKey
      $packageName = [string]$record.packageName
      $packageVersion = [string]$record.packageVersion
      if (-not $snapshotKey -or $snapshotKey -match '[\r\n]' -or $seenSnapshots.ContainsKey($snapshotKey)) {
        throw "official runtime resolutions have an invalid or duplicate snapshot: $snapshotKey"
      }
      $seenSnapshots[$snapshotKey] = $true
      if (-not $packageKey -or $packageKey -match '[\r\n]' -or
        $packageName -cnotmatch '^(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*$' -or
        -not $packageVersion -or $packageVersion -match '[\s/\\]') {
        throw "official runtime resolution has an invalid package identity: $snapshotKey"
      }
      if ($packageKey -cne "${packageName}@${packageVersion}" -or
        ($snapshotKey -cne $packageKey -and -not $snapshotKey.StartsWith("$packageKey(", [StringComparison]::Ordinal))) {
        throw "official runtime resolution has inconsistent package keys: $snapshotKey"
      }
      $resolutionProperties = @($record.resolution.PSObject.Properties)
      if ($resolutionProperties.Count -lt 1 -or $resolutionProperties.Count -gt 2 -or
        @($resolutionProperties | Where-Object {
          $_.Name -cnotmatch '^(?:integrity|tarball)$' -or
          -not [string]$_.Value -or [string]$_.Value -match '[\r\n]'
        }).Count -gt 0) {
        throw "official runtime resolution has an invalid source: $snapshotKey"
      }
      $integrity = $record.resolution.PSObject.Properties['integrity']
      $tarball = $record.resolution.PSObject.Properties['tarball']
      if (($null -ne $integrity -and [string]$integrity.Value -cnotmatch '^sha(?:1|256|384|512)-\S+$') -or
        ($null -ne $tarball -and [string]$tarball.Value -match '^(?:file|link):')) {
        throw "official runtime resolution has an invalid registry source: $snapshotKey"
      }
      $packageProperty = $record.PSObject.Properties['package']
      if ($null -eq $packageProperty -or $null -eq $packageProperty.Value) {
        throw "official runtime resolution has no package body: $snapshotKey"
      }
      [void](ConvertTo-DshVerifiedRuntimePackage -Value $packageProperty.Value -Description "official runtime package $packageKey")
      $snapshotProperty = $record.PSObject.Properties['snapshot']
      if ($null -eq $snapshotProperty -or $null -eq $snapshotProperty.Value) {
        throw "official runtime resolution has no snapshot body: $snapshotKey"
      }
      [void](ConvertTo-DshVerifiedRuntimeSnapshot -Value $snapshotProperty.Value -Description "official runtime snapshot $snapshotKey")
    }
    $runtimeResolutionsSha256 = Get-DshRuntimeResolutionsSha256 -Records $runtimeResolutions
    if ($runtimeResolutionsSha256 -cne [string]$provenance.runtimeResolutionsSha256) {
      throw 'official runtime resolution map failed SHA256 verification'
    }

    $internalRuntimeSnapshots = @($provenance.internalRuntimeSnapshots | ForEach-Object { $_ })
    if ($internalRuntimeSnapshots.Count -ne [int]$provenance.internalSnapshotCount -or
      $internalRuntimeSnapshots.Count -ne $internalRuntimePackages.Count) {
      throw 'official package provenance has an inconsistent internal runtime snapshot count'
    }
    $runtimePackagesByName = @{}
    foreach ($package in $internalRuntimePackages) { $runtimePackagesByName[[string]$package.Name] = $package }
    $seenInternalSnapshots = @{}
    foreach ($record in $internalRuntimeSnapshots) {
      $recordFields = @($record.PSObject.Properties.Name)
      $expectedRecordFields = @('package', 'packageKey', 'packageName', 'packageVersion', 'snapshot', 'snapshotKey')
      if ($recordFields.Count -ne $expectedRecordFields.Count -or
        @($recordFields | Where-Object { $_ -cnotin $expectedRecordFields }).Count -gt 0) {
        throw 'official internal runtime snapshot has unsupported record fields'
      }
      $name = [string]$record.packageName
      $version = [string]$record.packageVersion
      $packageKey = [string]$record.packageKey
      $snapshotKey = [string]$record.snapshotKey
      if (-not $runtimePackagesByName.ContainsKey($name) -or $seenInternalSnapshots.ContainsKey($name)) {
        throw "official internal runtime snapshots have an unknown or duplicate package: $name"
      }
      $seenInternalSnapshots[$name] = $true
      $package = $runtimePackagesByName[$name]
      $expectedPackageKey = "${name}@file:../$($package.RelativePath)"
      if ($version -cne [string]$package.Version -or $packageKey -cne $expectedPackageKey -or
        ($snapshotKey -cne $packageKey -and -not $snapshotKey.StartsWith("$packageKey(", [StringComparison]::Ordinal))) {
        throw "official internal runtime snapshot has inconsistent package identity: $name"
      }
      $packageProperty = $record.PSObject.Properties['package']
      if ($null -eq $packageProperty -or $null -eq $packageProperty.Value) {
        throw "official internal runtime snapshot has no package body: $name"
      }
      [void](ConvertTo-DshVerifiedRuntimePackage -Value $packageProperty.Value -Description "official internal runtime package $name")
      $snapshotProperty = $record.PSObject.Properties['snapshot']
      if ($null -eq $snapshotProperty -or $null -eq $snapshotProperty.Value) {
        throw "official internal runtime snapshot has no body: $name"
      }
      [void](ConvertTo-DshVerifiedRuntimeSnapshot -Value $snapshotProperty.Value -Description "official internal runtime snapshot $name")
    }
    $internalRuntimeSnapshotsSha256 = Get-DshCanonicalRecordsSha256 -Records $internalRuntimeSnapshots
    if ($internalRuntimeSnapshotsSha256 -cne [string]$provenance.internalRuntimeSnapshotsSha256) {
      throw 'official internal runtime snapshot map failed SHA256 verification'
    }

    $peerPinsProperty = $provenance.PSObject.Properties['consumerPeerPins']
    if ($null -eq $peerPinsProperty -or $null -eq $peerPinsProperty.Value) {
      throw 'official package provenance has no consumer peer pins'
    }
    $consumerPeerPins = [ordered]@{}
    foreach ($property in @($peerPinsProperty.Value.PSObject.Properties | Sort-Object Name)) {
      $name = [string]$property.Name
      $version = [string]$property.Value
      if ($name -cnotmatch '^(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*$' -or
        -not $version -or $version -match '[\s/\\]' -or $consumerPeerPins.Contains($name)) {
        throw "official package provenance has an invalid consumer peer pin: $name"
      }
      if (@($internalRuntimePackages | Where-Object { [string]$_.Name -ceq $name }).Count -gt 0) {
        throw "official consumer peer pin conflicts with internal package $name"
      }
      $consumerPeerPins[$name] = $version
    }
    if ($consumerPeerPins.Count -eq 0) { throw 'official package provenance has an empty consumer peer pin set' }
    if ([int]$provenance.consumerOverrideCount -lt $internalRuntimePackages.Count) {
      throw 'official package provenance has an implausible consumer override count'
    }
    $excludedProperty = $provenance.PSObject.Properties['excludedWindowsOptionalPackages']
    if ($null -eq $excludedProperty -or $null -eq $excludedProperty.Value) {
      throw 'official package provenance has no Windows optional-package exclusion map'
    }
    foreach ($property in @($excludedProperty.Value.PSObject.Properties)) {
      $name = [string]$property.Name
      $version = [string]$property.Value
      if ($name -cnotmatch '^@deepseek-ai/[a-z0-9][a-z0-9._-]*$' -or
        -not $version -or $version -match '[\s/\\]' -or
        @($internalRuntimePackages | Where-Object { [string]$_.Name -ceq $name }).Count -gt 0) {
        throw "official package provenance has an invalid Windows optional-package exclusion: $name"
      }
    }

    $consumerRoot = Join-Path $root 'consumer'
    $consumerRecords = @($provenance.consumerFiles | ForEach-Object { $_ })
    $consumerActual = @(Get-ChildItem -LiteralPath $consumerRoot -Recurse -File -ErrorAction Stop | Sort-Object FullName)
    if ($consumerRecords.Count -ne 3 -or $consumerActual.Count -ne 3) {
      throw 'official package input has an incomplete or unlisted consumer template file set'
    }
    $consumerPaths = @{}
    foreach ($file in $consumerActual) {
      $relative = Get-DshPackageRelativePath -Root $consumerRoot -Path $file.FullName
      if ($relative -cnotmatch '^(?:package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml)$') {
        throw "official consumer template has an unexpected file: $relative"
      }
      $consumerPaths[$relative] = $file.FullName
    }
    $consumerSeen = @{}
    foreach ($record in $consumerRecords) {
      $relative = [string]$record.relativePath
      if ($consumerSeen.ContainsKey($relative)) { throw "official consumer provenance duplicates file: $relative" }
      $consumerSeen[$relative] = $true
      if (-not $consumerPaths.ContainsKey($relative)) { throw "official consumer provenance names a missing file: $relative" }
      $file = [string]$consumerPaths[$relative]
      $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
      if ((Get-Item -LiteralPath $file).Length -ne [int64]$record.size -or $sha -cne [string]$record.sha256) {
        throw "official consumer template failed size or SHA256 verification: $relative"
      }
    }
    foreach ($required in @('package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml')) {
      if (-not $consumerSeen.ContainsKey($required)) { throw "official consumer template is missing $required" }
    }
    $controlProperty = $provenance.PSObject.Properties['consumerLockControl']
    if ($null -eq $controlProperty -or $null -eq $controlProperty.Value) {
      throw 'official package provenance has no consumer lock control model'
    }
    $verifiedControl = ConvertTo-DshPnpmConsumerLockControl `
      -Control $controlProperty.Value `
      -Description 'official consumer lock control'
    $consumerLockControl = $verifiedControl.Value
    $consumerLockControlSha256 = Get-DshCanonicalValueSha256 -Value $consumerLockControl
    if ($consumerLockControlSha256 -cne [string]$provenance.consumerLockControlSha256) {
      throw 'official consumer lock control failed SHA256 verification'
    }
    $candidateControl = Get-DshPnpmConsumerLockControl -LockPath (Join-Path $consumerRoot 'pnpm-lock.yaml')
    if ([string]$candidateControl.Json -cne [string]$verifiedControl.Json) {
      throw 'official consumer lock differs from its verified control model'
    }
    $consumerManifest = Get-Content -LiteralPath (Join-Path $consumerRoot 'package.json') -Raw | ConvertFrom-Json
    if ([string]$consumerManifest.name -cne 'deepseek-harness-portable-official-runtime' -or
      [string]$consumerManifest.version -cne '0.0.0' -or $consumerManifest.private -isnot [bool] -or
      -not [bool]$consumerManifest.private -or
      [string]$consumerManifest.packageManager -cne [string]$provenance.packageManager) {
      throw 'official consumer template has invalid package metadata'
    }
    $dependencyProperties = @($consumerManifest.dependencies.PSObject.Properties)
    $expectedDependencyCount = $internalRuntimePackages.Count + $consumerPeerPins.Count
    if ($dependencyProperties.Count -ne $expectedDependencyCount) {
      throw "official consumer template has $($dependencyProperties.Count) dependencies, expected $expectedDependencyCount"
    }
    $rootImporter = $consumerLockControl.importers.'.'
    $controlDependencies = $rootImporter.dependencies
    if ($controlDependencies.Count -ne $expectedDependencyCount) {
      throw "official consumer lock importer has $($controlDependencies.Count) dependencies, expected $expectedDependencyCount"
    }
    if ($consumerLockControl.overrides.Count -ne [int]$provenance.consumerOverrideCount) {
      throw 'official consumer lock override count differs from provenance'
    }
    $controlPatches = $consumerLockControl.patchedDependencies
    if ($controlPatches.Count -ne $patchedDependencies.Count) {
      throw 'official consumer lock patch count differs from provenance'
    }
    foreach ($name in $patchedDependencies.Keys) {
      if (-not $controlPatches.Contains([string]$name)) { throw "official consumer lock is missing patch selector $name" }
    }
    foreach ($package in $internalRuntimePackages) {
      $dependency = $consumerManifest.dependencies.PSObject.Properties[[string]$package.Name]
      $expectedSpecifier = "file:../$($package.RelativePath)"
      if ($null -eq $dependency -or [string]$dependency.Value -cne $expectedSpecifier) {
        throw "official consumer template is missing exact runtime archive $($package.Name)"
      }
      $controlDependency = $controlDependencies[[string]$package.Name]
      if ($null -eq $controlDependency -or [string]$controlDependency.specifier -cne $expectedSpecifier) {
        throw "official consumer lock importer is missing exact runtime archive $($package.Name)"
      }
    }
    foreach ($name in $consumerPeerPins.Keys) {
      $dependency = $consumerManifest.dependencies.PSObject.Properties[[string]$name]
      if ($null -eq $dependency -or [string]$dependency.Value -cne [string]$consumerPeerPins[$name]) {
        throw "official consumer template is missing exact peer pin $name"
      }
      $controlDependency = $controlDependencies[[string]$name]
      if ($null -eq $controlDependency -or
        [string]$controlDependency.specifier -cne [string]$consumerPeerPins[$name]) {
        throw "official consumer lock importer is missing exact peer pin $name"
      }
    }
    $consumerLockSha256 = (Get-FileHash -LiteralPath (Join-Path $consumerRoot 'pnpm-lock.yaml') -Algorithm SHA256).Hash.ToLowerInvariant()
    $consumerFiles = $consumerRecords
  }
  return [pscustomobject]@{
    AllowBuilds = $allowBuilds
    ConsumerDirectory = $consumerRoot
    ConsumerFiles = $consumerFiles
    ConsumerLockControl = $consumerLockControl
    ConsumerLockControlSha256 = $consumerLockControlSha256
    ConsumerLockSha256 = $consumerLockSha256
    ExternalRuntimeResolutions = $runtimeResolutions
    ExternalRuntimeResolutionsSha256 = $runtimeResolutionsSha256
    InternalRuntimePackages = $internalRuntimePackages
    InternalRuntimeSnapshots = $internalRuntimeSnapshots
    InternalRuntimeSnapshotsSha256 = $internalRuntimeSnapshotsSha256
    PackageManager = [string]$provenance.packageManager
    Packages = $verified
    PatchedDependencies = $patchedDependencies
    Provenance = $provenance
    ProvenanceSha256 = (Get-FileHash -LiteralPath $provenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
    RuntimeLockDirectory = $runtimeRoot
    RuntimeLockSha256 = (Get-FileHash -LiteralPath (Join-Path $runtimeRoot 'pnpm-lock.yaml') -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}
