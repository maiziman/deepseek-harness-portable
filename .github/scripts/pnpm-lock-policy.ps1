# Verify that a generated portable lock is exactly the external runtime closure
# derived from the official source and contains only explicitly allowed local
# packages rebuilt from verified archives.
Set-StrictMode -Version Latest

function New-DshPnpmOrdinalDictionary {
  return ,([Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal))
}

function ConvertFrom-DshPnpmYamlKey {
  param([Parameter(Mandatory)][string]$Value)

  if ($Value.StartsWith("'") -and $Value.EndsWith("'")) {
    return $Value.Substring(1, $Value.Length - 2).Replace("''", "'")
  }
  if ($Value.StartsWith('"') -and $Value.EndsWith('"')) {
    return [string]($Value | ConvertFrom-Json)
  }
  return $Value
}

function ConvertFrom-DshPnpmResolution {
  param([Parameter(Mandatory)][string]$Value)

  $trimmed = $Value.Trim()
  if (-not $trimmed.StartsWith('{') -or -not $trimmed.EndsWith('}')) {
    throw "pnpm lock has an unsupported resolution: $Value"
  }
  $inner = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
  if (-not $inner) { throw 'pnpm lock has an empty resolution' }

  $parts = [Collections.Generic.List[string]]::new()
  $start = 0
  $quote = [char]0
  $escaped = $false
  for ($index = 0; $index -lt $inner.Length; $index++) {
    $character = $inner[$index]
    if ($quote -ne [char]0) {
      if ($quote -eq '"') {
        if ($escaped) { $escaped = $false; continue }
        if ($character -eq '\') { $escaped = $true; continue }
      } elseif ($character -eq "'" -and $index + 1 -lt $inner.Length -and $inner[$index + 1] -eq "'") {
        $index++
        continue
      }
      if ($character -eq $quote) { $quote = [char]0 }
      continue
    }
    if ($character -eq "'" -or $character -eq '"') { $quote = $character; continue }
    if ($character -eq '{' -or $character -eq '}' -or $character -eq '[' -or $character -eq ']') {
      throw "pnpm lock resolution contains a nested value: $Value"
    }
    if ($character -eq ',') {
      $parts.Add($inner.Substring($start, $index - $start).Trim())
      $start = $index + 1
    }
  }
  if ($quote -ne [char]0 -or $escaped) { throw "pnpm lock resolution has an unterminated scalar: $Value" }
  $parts.Add($inner.Substring($start).Trim())

  $fields = New-DshPnpmOrdinalDictionary
  foreach ($part in $parts) {
    $match = [regex]::Match($part, '^(?<key>[A-Za-z][A-Za-z0-9_-]*):\s*(?<value>.+)$')
    if (-not $match.Success) { throw "pnpm lock has an invalid resolution field: $part" }
    $key = [string]$match.Groups['key'].Value
    if ($key -cnotin @('directory', 'integrity', 'tarball', 'type')) {
      throw "pnpm lock has an unsupported resolution field: $key"
    }
    if ($fields.Contains($key)) { throw "pnpm lock resolution duplicates field: $key" }
    $scalar = [string]$match.Groups['value'].Value.Trim()
    if (($scalar.StartsWith("'") -and $scalar.EndsWith("'")) -or
      ($scalar.StartsWith('"') -and $scalar.EndsWith('"'))) {
      $scalar = ConvertFrom-DshPnpmYamlKey -Value $scalar
    }
    if (-not $scalar -or $scalar -match '[\r\n]') { throw "pnpm lock has an invalid $key resolution" }
    $fields.Add($key, $scalar)
  }

  return ConvertFrom-DshPnpmResolutionFields -Fields $fields
}

function ConvertFrom-DshPnpmResolutionFields {
  param([Parameter(Mandatory)][Collections.IDictionary]$Fields)

  if ($Fields.Count -eq 0) { throw 'pnpm lock has an empty resolution' }
  $canonical = [ordered]@{}
  foreach ($key in @($Fields.Keys | Sort-Object)) { $canonical[$key] = [string]$Fields[$key] }
  return [pscustomobject]@{
    Fields = $Fields
    Json = ($canonical | ConvertTo-Json -Compress)
  }
}

function ConvertTo-DshPnpmExpectedResolution {
  param(
    [Parameter(Mandatory)][object]$Resolution,
    [Parameter(Mandatory)][string]$Description
  )

  $fields = New-DshPnpmOrdinalDictionary
  if ($Resolution -is [Collections.IDictionary]) {
    foreach ($keyValue in $Resolution.Keys) {
      $key = [string]$keyValue
      if ($fields.Contains($key)) { throw "$Description duplicates resolution field $key" }
      $fields.Add($key, [string]$Resolution[$keyValue])
    }
  } else {
    foreach ($property in @($Resolution.PSObject.Properties)) {
      $key = [string]$property.Name
      if ($fields.Contains($key)) { throw "$Description duplicates resolution field $key" }
      $fields.Add($key, [string]$property.Value)
    }
  }
  if ($fields.Count -eq 0) { throw "$Description has an empty resolution" }
  foreach ($key in $fields.Keys) {
    if ([string]$key -cnotin @('integrity', 'tarball') -or -not [string]$fields[$key]) {
      throw "$Description has an unsupported resolution field: $key"
    }
  }
  $canonical = [ordered]@{}
  foreach ($key in @($fields.Keys | Sort-Object)) { $canonical[$key] = [string]$fields[$key] }
  return [pscustomobject]@{
    Fields = $fields
    Json = ($canonical | ConvertTo-Json -Compress)
  }
}

function ConvertTo-DshPnpmSnapshotBody {
  param(
    [Parameter(Mandatory)][object]$Snapshot,
    [Parameter(Mandatory)][string]$Description
  )

  $properties = New-DshPnpmOrdinalDictionary
  if ($Snapshot -is [Collections.IDictionary]) {
    foreach ($keyValue in $Snapshot.Keys) {
      $key = [string]$keyValue
      if ($properties.Contains($key)) { throw "$Description duplicates field $key" }
      $properties.Add($key, $Snapshot[$keyValue])
    }
  } else {
    foreach ($property in @($Snapshot.PSObject.Properties)) {
      $key = [string]$property.Name
      if ($properties.Contains($key)) { throw "$Description duplicates field $key" }
      $properties.Add($key, $property.Value)
    }
  }
  foreach ($keyValue in $properties.Keys) {
    $key = [string]$keyValue
    if ($key -cnotin @('dependencies', 'id', 'optional', 'optionalDependencies', 'transitivePeerDependencies')) {
      throw "$Description has unsupported field $key"
    }
  }

  $canonical = [ordered]@{}
  foreach ($field in @('dependencies', 'optionalDependencies')) {
    if (-not $properties.Contains($field)) { continue }
    $value = $properties[$field]
    $dependencies = New-DshPnpmOrdinalDictionary
    if ($value -is [Collections.IDictionary]) {
      foreach ($keyValue in $value.Keys) {
        $name = [string]$keyValue
        if ($dependencies.Contains($name)) { throw "$Description.$field duplicates package $name" }
        $dependencies.Add($name, [string]$value[$keyValue])
      }
    } else {
      foreach ($property in @($value.PSObject.Properties)) {
        $name = [string]$property.Name
        if ($dependencies.Contains($name)) { throw "$Description.$field duplicates package $name" }
        $dependencies.Add($name, [string]$property.Value)
      }
    }
    $normalized = [ordered]@{}
    foreach ($nameValue in @($dependencies.Keys | Sort-Object)) {
      $name = [string]$nameValue
      $locator = [string]$dependencies[$name]
      if (-not $name -or $name -match '[\r\n]' -or -not $locator -or $locator -match '[\r\n]') {
        throw "$Description.$field has an invalid package locator"
      }
      $normalized[$name] = $locator
    }
    if ($normalized.Count -gt 0) { $canonical[$field] = $normalized }
  }
  if ($properties.Contains('transitivePeerDependencies')) {
    $value = $properties['transitivePeerDependencies']
    if ($value -is [string] -or $null -eq $value) {
      throw "$Description.transitivePeerDependencies is not an array"
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $peers = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($value)) {
      $name = [string]$entry
      if (-not $name -or $name -match '[\r\n]' -or -not $seen.Add($name)) {
        throw "$Description.transitivePeerDependencies has an invalid or duplicate package name"
      }
      $peers.Add($name)
    }
    $peers.Sort([StringComparer]::Ordinal)
    if ($peers.Count -gt 0) { $canonical['transitivePeerDependencies'] = @($peers) }
  }
  if ($properties.Contains('optional')) {
    $value = $properties['optional']
    if ($value -isnot [bool]) { throw "$Description.optional is not boolean" }
    $canonical['optional'] = [bool]$value
  }
  if ($properties.Contains('id')) {
    $value = [string]$properties['id']
    if (-not $value -or $value -match '[\r\n]') { throw "$Description.id is not a non-empty scalar" }
    $canonical['id'] = $value
  }
  return [pscustomobject]@{
    Value = [pscustomobject]$canonical
    Json = ($canonical | ConvertTo-Json -Depth 8 -Compress)
  }
}

function ConvertTo-DshPnpmPackageBody {
  param(
    [Parameter(Mandatory)][object]$Package,
    [Parameter(Mandatory)][string]$Description
  )

  $properties = New-DshPnpmOrdinalDictionary
  if ($Package -is [Collections.IDictionary]) {
    foreach ($keyValue in $Package.Keys) { $properties.Add([string]$keyValue, $Package[$keyValue]) }
  } else {
    foreach ($property in @($Package.PSObject.Properties)) { $properties.Add([string]$property.Name, $property.Value) }
  }
  foreach ($keyValue in $properties.Keys) {
    $key = [string]$keyValue
    if ($key -cnotin @('bundledDependencies', 'cpu', 'deprecated', 'engines', 'hasBin', 'libc', 'name', 'os',
        'peerDependencies', 'peerDependenciesMeta', 'version')) {
      throw "$Description has unsupported field $key"
    }
  }

  $canonical = [ordered]@{}
  if ($properties.Contains('bundledDependencies')) {
    $value = $properties['bundledDependencies']
    if ($value -is [bool]) {
      if (-not [bool]$value) { throw "$Description.bundledDependencies only supports true or a package list" }
      $canonical['bundledDependencies'] = $true
    } else {
      if ($value -is [string] -or $null -eq $value) { throw "$Description.bundledDependencies is not an array" }
      $entries = [Collections.Generic.List[string]]::new()
      $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      foreach ($entry in @($value)) {
        $name = [string]$entry
        if (-not $name -or $name -match '[\r\n]' -or -not $seen.Add($name)) {
          throw "$Description.bundledDependencies has an invalid or duplicate package name"
        }
        $entries.Add($name)
      }
      $entries.Sort([StringComparer]::Ordinal)
      if ($entries.Count -gt 0) { $canonical['bundledDependencies'] = @($entries) }
    }
  }
  foreach ($field in @('cpu', 'libc', 'os')) {
    if (-not $properties.Contains($field)) { continue }
    $value = $properties[$field]
    if ($value -is [string] -or $null -eq $value) { throw "$Description.$field is not an array" }
    $entries = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($value)) {
      $name = [string]$entry
      if (-not $name -or $name -match '[\r\n]' -or -not $seen.Add($name)) {
        throw "$Description.$field has an invalid or duplicate entry"
      }
      $entries.Add($name)
    }
    $entries.Sort([StringComparer]::Ordinal)
    if ($entries.Count -gt 0) { $canonical[$field] = @($entries) }
  }
  foreach ($field in @('deprecated', 'name')) {
    if (-not $properties.Contains($field)) { continue }
    $value = [string]$properties[$field]
    if (-not $value -or $value -match '[\r\n]') { throw "$Description.$field is not a non-empty scalar" }
    $canonical[$field] = $value
  }
  foreach ($field in @('engines', 'peerDependencies')) {
    if (-not $properties.Contains($field)) { continue }
    $value = $properties[$field]
    $mapping = New-DshPnpmOrdinalDictionary
    if ($value -is [Collections.IDictionary]) {
      foreach ($keyValue in $value.Keys) { $mapping.Add([string]$keyValue, [string]$value[$keyValue]) }
    } else {
      foreach ($property in @($value.PSObject.Properties)) { $mapping.Add([string]$property.Name, [string]$property.Value) }
    }
    $normalized = [ordered]@{}
    foreach ($nameValue in @($mapping.Keys | Sort-Object)) {
      $name = [string]$nameValue
      $range = [string]$mapping[$name]
      if (-not $name -or $name -match '[\r\n]' -or -not $range -or $range -match '[\r\n]') {
        throw "$Description.$field has an invalid entry"
      }
      $normalized[$name] = $range
    }
    if ($normalized.Count -gt 0) { $canonical[$field] = $normalized }
  }
  if ($properties.Contains('hasBin')) {
    if ($properties['hasBin'] -isnot [bool]) { throw "$Description.hasBin is not boolean" }
    $canonical['hasBin'] = [bool]$properties['hasBin']
  }
  if ($properties.Contains('peerDependenciesMeta')) {
    $value = $properties['peerDependenciesMeta']
    $mapping = New-DshPnpmOrdinalDictionary
    if ($value -is [Collections.IDictionary]) {
      foreach ($keyValue in $value.Keys) { $mapping.Add([string]$keyValue, $value[$keyValue]) }
    } else {
      foreach ($property in @($value.PSObject.Properties)) { $mapping.Add([string]$property.Name, $property.Value) }
    }
    $normalized = [ordered]@{}
    foreach ($nameValue in @($mapping.Keys | Sort-Object)) {
      $name = [string]$nameValue
      $meta = $mapping[$name]
      $metaKeys = if ($meta -is [Collections.IDictionary]) { @($meta.Keys) } else { @($meta.PSObject.Properties.Name) }
      $optionalValue = if ($meta -is [Collections.IDictionary]) { $meta['optional'] } else { $meta.PSObject.Properties['optional'].Value }
      if (-not $name -or $name -match '[\r\n]' -or @($metaKeys).Count -ne 1 -or
        [string](@($metaKeys)[0]) -cne 'optional' -or $optionalValue -isnot [bool]) {
        throw "$Description.peerDependenciesMeta.$name is unsupported"
      }
      $normalized[$name] = [ordered]@{ optional = [bool]$optionalValue }
    }
    if ($normalized.Count -gt 0) { $canonical['peerDependenciesMeta'] = $normalized }
  }
  if ($properties.Contains('version')) {
    $value = [string]$properties['version']
    if (-not $value -or $value -match '[\r\n]') { throw "$Description.version is not a non-empty scalar" }
    $canonical['version'] = $value
  }
  return [pscustomobject]@{
    Value = [pscustomobject]$canonical
    Json = ($canonical | ConvertTo-Json -Depth 8 -Compress)
  }
}

function Get-DshPnpmObjectMap {
  param(
    [Parameter(Mandatory)][object]$Value,
    [Parameter(Mandatory)][string]$Description
  )

  if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType] -or $Value -is [array]) {
    throw "$Description is not an object"
  }
  $result = New-DshPnpmOrdinalDictionary
  if ($Value -is [Collections.IDictionary]) {
    foreach ($keyValue in $Value.Keys) {
      $key = [string]$keyValue
      if ($result.Contains($key)) { throw "$Description duplicates field $key" }
      $result.Add($key, $Value[$keyValue])
    }
  } else {
    foreach ($property in @($Value.PSObject.Properties)) {
      $key = [string]$property.Name
      if ($result.Contains($key)) { throw "$Description duplicates field $key" }
      $result.Add($key, $property.Value)
    }
  }
  return ,$result
}

function Get-DshPnpmSortedKeys {
  param([Parameter(Mandatory)][Collections.IDictionary]$Map)

  [string[]]$keys = @($Map.Keys | ForEach-Object { [string]$_ })
  [Array]::Sort($keys, [StringComparer]::Ordinal)
  return ,$keys
}

function Assert-DshPnpmExactObjectFields {
  param(
    [Parameter(Mandatory)][Collections.IDictionary]$Map,
    [Parameter(Mandatory)][string[]]$Fields,
    [Parameter(Mandatory)][string]$Description
  )

  $expected = [Collections.Generic.HashSet[string]]::new($Fields, [StringComparer]::Ordinal)
  if ($Map.Count -ne $expected.Count) {
    throw "$Description has unsupported or missing fields"
  }
  foreach ($keyValue in $Map.Keys) {
    $key = [string]$keyValue
    if (-not $expected.Contains($key)) { throw "$Description has unsupported field $key" }
  }
}

function ConvertTo-DshPnpmConsumerLockControl {
  param(
    [Parameter(Mandatory)][object]$Control,
    [Parameter(Mandatory)][string]$Description
  )

  $root = Get-DshPnpmObjectMap -Value $Control -Description $Description
  Assert-DshPnpmExactObjectFields `
    -Map $root `
    -Fields @('importers', 'lockfileVersion', 'overrides', 'patchedDependencies', 'settings') `
    -Description $Description
  $lockfileVersion = [string]$root['lockfileVersion']
  if ($lockfileVersion -cne '9.0') { throw "$Description.lockfileVersion is not 9.0" }

  $settings = Get-DshPnpmObjectMap -Value $root['settings'] -Description "$Description.settings"
  Assert-DshPnpmExactObjectFields `
    -Map $settings `
    -Fields @('autoInstallPeers', 'excludeLinksFromLockfile') `
    -Description "$Description.settings"
  $canonicalSettings = [ordered]@{}
  foreach ($field in @('autoInstallPeers', 'excludeLinksFromLockfile')) {
    if ($settings[$field] -isnot [bool]) { throw "$Description.settings.$field is not boolean" }
    $canonicalSettings[$field] = [bool]$settings[$field]
  }

  $canonicalMaps = @{}
  foreach ($field in @('overrides', 'patchedDependencies')) {
    $mapping = Get-DshPnpmObjectMap -Value $root[$field] -Description "$Description.$field"
    $canonical = [ordered]@{}
    foreach ($key in (Get-DshPnpmSortedKeys -Map $mapping)) {
      $value = $mapping[$key]
      if (-not $key -or $key -match '[\r\n]' -or $value -isnot [string] -or
        -not [string]$value -or [string]$value -match '[\r\n]') {
        throw "$Description.$field has an invalid entry"
      }
      $canonical[$key] = [string]$value
    }
    $canonicalMaps[$field] = $canonical
  }

  $importers = Get-DshPnpmObjectMap -Value $root['importers'] -Description "$Description.importers"
  Assert-DshPnpmExactObjectFields -Map $importers -Fields @('.') -Description "$Description.importers"
  $importer = Get-DshPnpmObjectMap -Value $importers['.'] -Description "$Description.importers."
  Assert-DshPnpmExactObjectFields -Map $importer -Fields @('dependencies') -Description "$Description.importers."
  $dependencies = Get-DshPnpmObjectMap `
    -Value $importer['dependencies'] `
    -Description "$Description.importers...dependencies"
  $canonicalDependencies = [ordered]@{}
  foreach ($name in (Get-DshPnpmSortedKeys -Map $dependencies)) {
    if (-not $name -or $name -match '[\r\n]') {
      throw "$Description.importers...dependencies has an invalid package name"
    }
    $entry = Get-DshPnpmObjectMap `
      -Value $dependencies[$name] `
      -Description "$Description.importers...dependencies.$name"
    Assert-DshPnpmExactObjectFields `
      -Map $entry `
      -Fields @('specifier', 'version') `
      -Description "$Description.importers...dependencies.$name"
    $canonicalEntry = [ordered]@{}
    foreach ($field in @('specifier', 'version')) {
      $value = $entry[$field]
      if ($value -isnot [string] -or -not [string]$value -or [string]$value -match '[\r\n]') {
        throw "$Description.importers...dependencies.$name.$field is not a non-empty scalar"
      }
      $canonicalEntry[$field] = [string]$value
    }
    $canonicalDependencies[$name] = $canonicalEntry
  }

  $canonical = [ordered]@{
    importers = [ordered]@{ '.' = [ordered]@{ dependencies = $canonicalDependencies } }
    lockfileVersion = $lockfileVersion
    overrides = $canonicalMaps['overrides']
    patchedDependencies = $canonicalMaps['patchedDependencies']
    settings = $canonicalSettings
  }
  return [pscustomobject]@{
    Value = [pscustomobject]$canonical
    Json = ($canonical | ConvertTo-Json -Depth 8 -Compress)
  }
}

function ConvertFrom-DshPnpmControlScalar {
  param(
    [Parameter(Mandatory)][string]$Value,
    [Parameter(Mandatory)][string]$Description
  )

  $scalar = $Value.Trim()
  if (($scalar.StartsWith("'") -and $scalar.EndsWith("'")) -or
    ($scalar.StartsWith('"') -and $scalar.EndsWith('"'))) {
    $scalar = ConvertFrom-DshPnpmYamlKey -Value $scalar
  }
  if (-not $scalar -or $scalar -match '[\r\n{}\[\]]') { throw "$Description has an invalid scalar" }
  return $scalar
}

function Get-DshPnpmConsumerLockControl {
  param([Parameter(Mandatory)][string]$LockPath)

  if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { throw "pnpm lockfile is missing: $LockPath" }
  $rootFields = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $settings = New-DshPnpmOrdinalDictionary
  $overrides = New-DshPnpmOrdinalDictionary
  $patchedDependencies = New-DshPnpmOrdinalDictionary
  $dependencies = New-DshPnpmOrdinalDictionary
  $lockfileVersion = ''
  $section = ''
  $importerSeen = $false
  $dependenciesSeen = $false
  $currentDependency = ''
  $currentDependencyFields = New-DshPnpmOrdinalDictionary
  $finishDependency = {
    if (-not $currentDependency) { return }
    Assert-DshPnpmExactObjectFields `
      -Map $currentDependencyFields `
      -Fields @('specifier', 'version') `
      -Description "pnpm root importer dependency $currentDependency"
    $dependencies.Add($currentDependency, [pscustomobject][ordered]@{
      specifier = [string]$currentDependencyFields['specifier']
      version = [string]$currentDependencyFields['version']
    })
    $currentDependency = ''
    $currentDependencyFields = New-DshPnpmOrdinalDictionary
  }

  foreach ($line in @(Get-Content -LiteralPath $LockPath)) {
    if (-not $line -or $line -cmatch '^\s*#') { continue }
    if ($line -cmatch '^\S') {
      . $finishDependency
      $root = [regex]::Match($line, '^(?<key>[A-Za-z][A-Za-z0-9_-]*):(?:\s*(?<value>.*))?$')
      if (-not $root.Success) { throw "pnpm lock has a malformed root field: $line" }
      $key = [string]$root.Groups['key'].Value
      if ($key -cnotin @('importers', 'lockfileVersion', 'overrides', 'packages', 'patchedDependencies', 'settings', 'snapshots')) {
        throw "pnpm lock has an unsupported root field: $key"
      }
      if (-not $rootFields.Add($key)) { throw "pnpm lock duplicates root field: $key" }
      $value = [string]$root.Groups['value'].Value
      if ($key -ceq 'lockfileVersion') {
        $lockfileVersion = ConvertFrom-DshPnpmControlScalar -Value $value -Description 'pnpm lockfileVersion'
        $section = ''
      } else {
        if ($value) { throw "pnpm lock root section $key has an unsupported inline value" }
        $section = $key
      }
      continue
    }
    if ($section -cin @('packages', 'snapshots')) { continue }
    if ($section -ceq 'settings') {
      $entry = [regex]::Match($line, '^  (?<key>[A-Za-z][A-Za-z0-9_-]*):\s*(?<value>true|false)\s*$')
      if (-not $entry.Success) { throw "pnpm lock settings has an unsupported or malformed entry: $line" }
      $key = [string]$entry.Groups['key'].Value
      if ($key -cnotin @('autoInstallPeers', 'excludeLinksFromLockfile')) {
        throw "pnpm lock settings has unsupported field $key"
      }
      if ($settings.Contains($key)) { throw "pnpm lock settings duplicates field $key" }
      $settings.Add($key, [string]$entry.Groups['value'].Value -ceq 'true')
      continue
    }
    if ($section -cin @('overrides', 'patchedDependencies')) {
      $entry = [regex]::Match($line, '^  (?<key>.+):\s+(?<value>\S.*)\s*$')
      if (-not $entry.Success) { throw "pnpm lock $section has an unsupported or malformed entry: $line" }
      $key = ConvertFrom-DshPnpmYamlKey -Value ([string]$entry.Groups['key'].Value)
      $value = ConvertFrom-DshPnpmControlScalar `
        -Value ([string]$entry.Groups['value'].Value) `
        -Description "pnpm lock $section.$key"
      $mapping = if ($section -ceq 'overrides') { $overrides } else { $patchedDependencies }
      if (-not $key -or $key -match '[\r\n]' -or $mapping.Contains($key)) {
        throw "pnpm lock $section has a missing or duplicate key: $key"
      }
      $mapping.Add($key, $value)
      continue
    }
    if ($section -ceq 'importers') {
      if ($line -ceq '  .:') {
        . $finishDependency
        if ($importerSeen) { throw 'pnpm lock importers duplicates the root importer' }
        $importerSeen = $true
        continue
      }
      if ($line -ceq '    dependencies:') {
        . $finishDependency
        if (-not $importerSeen -or $dependenciesSeen) { throw 'pnpm lock root importer has an invalid dependencies field' }
        $dependenciesSeen = $true
        continue
      }
      $dependency = [regex]::Match($line, '^      (?<key>\S.*):\s*$')
      if ($dependency.Success) {
        . $finishDependency
        if (-not $dependenciesSeen) { throw 'pnpm lock root importer dependency appears before dependencies' }
        $currentDependency = ConvertFrom-DshPnpmYamlKey -Value ([string]$dependency.Groups['key'].Value)
        if (-not $currentDependency -or $currentDependency -match '[\r\n]' -or $dependencies.Contains($currentDependency)) {
          throw "pnpm lock root importer has a missing or duplicate dependency: $currentDependency"
        }
        continue
      }
      $field = [regex]::Match($line, '^        (?<key>specifier|version):\s*(?<value>\S.*)\s*$')
      if ($field.Success) {
        if (-not $currentDependency) { throw 'pnpm lock root importer has a dependency field without a package' }
        $key = [string]$field.Groups['key'].Value
        if ($currentDependencyFields.Contains($key)) {
          throw "pnpm lock root importer dependency $currentDependency duplicates field $key"
        }
        $currentDependencyFields.Add($key, (ConvertFrom-DshPnpmControlScalar `
          -Value ([string]$field.Groups['value'].Value) `
          -Description "pnpm root importer dependency $currentDependency.$key"))
        continue
      }
      throw "pnpm lock importers has an unsupported or malformed entry: $line"
    }
    throw "pnpm lock has content outside a supported root section: $line"
  }
  . $finishDependency
  $requiredRoot = @('importers', 'lockfileVersion', 'overrides', 'packages', 'patchedDependencies', 'settings', 'snapshots')
  if ($rootFields.Count -ne $requiredRoot.Count -or @($requiredRoot | Where-Object { -not $rootFields.Contains($_) }).Count -ne 0) {
    throw 'pnpm lock does not contain the complete supported root field set'
  }
  if (-not $importerSeen -or -not $dependenciesSeen) { throw 'pnpm lock has no complete root importer' }
  return ConvertTo-DshPnpmConsumerLockControl `
    -Control ([pscustomobject][ordered]@{
      importers = [pscustomobject][ordered]@{
        '.' = [pscustomobject][ordered]@{ dependencies = $dependencies }
      }
      lockfileVersion = $lockfileVersion
      overrides = $overrides
      patchedDependencies = $patchedDependencies
      settings = $settings
    }) `
    -Description 'pnpm lock control'
}

function Get-DshPnpmLockSectionEntries {
  param(
    [Parameter(Mandatory)][string]$LockPath,
    [Parameter(Mandatory)][ValidateSet('packages', 'snapshots')][string]$Section
  )

  if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { throw "pnpm lockfile is missing: $LockPath" }
  $lines = @(Get-Content -LiteralPath $LockPath)
  $sectionCount = @($lines | Where-Object { $_ -ceq "${Section}:" }).Count
  if ($sectionCount -ne 1) { throw "pnpm lockfile must contain exactly one $Section section: $LockPath" }
  $inside = $false
  $currentKey = ''
  $currentResolution = $null
  $currentResolutionFields = New-DshPnpmOrdinalDictionary
  $nestedResolution = $false
  $currentVersion = ''
  $currentVersionSeen = $false
  $currentPackage = New-DshPnpmOrdinalDictionary
  $packageMapField = ''
  $packageListField = ''
  $packagePeerMetaName = ''
  $currentSnapshot = New-DshPnpmOrdinalDictionary
  $snapshotMapField = ''
  $snapshotListField = ''
  $pendingExplicitKey = ''
  $records = New-DshPnpmOrdinalDictionary
  $finishEntry = {
    if (-not $currentKey) { return }
    if ($records.Contains($currentKey)) { throw "pnpm lock duplicates $Section entry: $currentKey" }
    if ($Section -ceq 'packages') {
      if ($null -eq $currentResolution) {
        if ($currentResolutionFields.Count -eq 0) { throw "pnpm package entry has no resolution: $currentKey" }
        $currentResolution = ConvertFrom-DshPnpmResolutionFields -Fields $currentResolutionFields
      }
      $package = ConvertTo-DshPnpmPackageBody -Package $currentPackage -Description "pnpm package $currentKey"
      $records.Add($currentKey, [pscustomobject]@{
        Key = $currentKey
        Resolution = $currentResolution
        Package = $package.Value
        PackageJson = $package.Json
        Version = $currentVersion
      })
    } else {
      $snapshot = ConvertTo-DshPnpmSnapshotBody -Snapshot $currentSnapshot -Description "pnpm snapshot $currentKey"
      $records.Add($currentKey, [pscustomobject]@{
        Key = $currentKey
        Snapshot = $snapshot.Value
        SnapshotJson = $snapshot.Json
      })
    }
  }
  foreach ($line in $lines) {
    if (-not $inside) {
      if ($line -ceq "${Section}:") { $inside = $true }
      continue
    }
    if ($nestedResolution) {
      $nestedField = [regex]::Match($line, '^      (?<key>[A-Za-z][A-Za-z0-9_-]*):\s*(?<value>\S.*)\s*$')
      if ($nestedField.Success) {
        $key = [string]$nestedField.Groups['key'].Value
        if ($key -cnotin @('directory', 'integrity', 'tarball', 'type')) {
          throw "pnpm lock has an unsupported resolution field: $key"
        }
        if ($currentResolutionFields.Contains($key)) { throw "pnpm lock resolution duplicates field: $key" }
        $scalar = [string]$nestedField.Groups['value'].Value.Trim()
        if (($scalar.StartsWith("'") -and $scalar.EndsWith("'")) -or
          ($scalar.StartsWith('"') -and $scalar.EndsWith('"'))) {
          $scalar = ConvertFrom-DshPnpmYamlKey -Value $scalar
        }
        if (-not $scalar -or $scalar -match '[\r\n{}\[\]]') { throw "pnpm lock has an invalid $key resolution" }
        $currentResolutionFields.Add($key, $scalar)
        continue
      }
      if ($line -cmatch '^      \S') { throw "pnpm lock resolution contains an invalid or nested value: $currentKey" }
      $nestedResolution = $false
    }
    if ($line -cmatch '^\S') {
      if ($pendingExplicitKey) { throw "pnpm lock has an incomplete explicit $Section key: $pendingExplicitKey" }
      & $finishEntry
      $currentKey = ''
      break
    }
    $explicitKey = [regex]::Match($line, '^  \? (?<key>\S.*)$')
    if ($explicitKey.Success) {
      if ($pendingExplicitKey) { throw "pnpm lock has adjacent explicit $Section keys" }
      & $finishEntry
      $currentKey = ''
      $currentResolution = $null
      $currentResolutionFields = New-DshPnpmOrdinalDictionary
      $nestedResolution = $false
      $currentVersion = ''
      $currentVersionSeen = $false
      $currentPackage = New-DshPnpmOrdinalDictionary
      $packageMapField = ''
      $packageListField = ''
      $packagePeerMetaName = ''
      $currentSnapshot = New-DshPnpmOrdinalDictionary
      $snapshotMapField = ''
      $snapshotListField = ''
      $pendingExplicitKey = ConvertFrom-DshPnpmYamlKey -Value ([string]$explicitKey.Groups['key'].Value)
      continue
    }
    if ($pendingExplicitKey) {
      $explicitValue = [regex]::Match($line, '^  :(?:\s*(?<value>.*))?$')
      if (-not $explicitValue.Success) { throw "pnpm lock has an invalid explicit $Section entry: $pendingExplicitKey" }
      $currentKey = $pendingExplicitKey
      $pendingExplicitKey = ''
      $currentResolution = $null
      $currentResolutionFields = New-DshPnpmOrdinalDictionary
      $nestedResolution = $false
      $currentVersion = ''
      $currentVersionSeen = $false
      $currentPackage = New-DshPnpmOrdinalDictionary
      $packageMapField = ''
      $packageListField = ''
      $packagePeerMetaName = ''
      $currentSnapshot = New-DshPnpmOrdinalDictionary
      $snapshotMapField = ''
      $snapshotListField = ''
      if ($Section -ceq 'packages') {
        $explicitBody = [string]$explicitValue.Groups['value'].Value
        $inlineResolution = [regex]::Match($explicitBody, '^resolution:\s*(?<value>\{.*\})\s*$')
        if ($inlineResolution.Success) {
          $currentResolution = ConvertFrom-DshPnpmResolution -Value ([string]$inlineResolution.Groups['value'].Value)
        } elseif ($explicitBody -ceq 'resolution:') {
          $nestedResolution = $true
        } elseif ($explicitBody) {
          throw "pnpm lock has an unsupported explicit package value: $currentKey"
        }
      } else {
        $explicitBody = [string]$explicitValue.Groups['value'].Value
        if (-not $explicitBody -or $explicitBody -ceq '{}') { continue }
        $explicitMap = [regex]::Match($explicitBody, '^(?<field>dependencies|optionalDependencies):(?:\s*\{\})?\s*$')
        if ($explicitMap.Success) {
          $field = [string]$explicitMap.Groups['field'].Value
          $currentSnapshot.Add($field, (New-DshPnpmOrdinalDictionary))
          $snapshotMapField = $field
        } elseif ($explicitBody -ceq 'transitivePeerDependencies:') {
          $currentSnapshot.Add('transitivePeerDependencies', [Collections.Generic.List[string]]::new())
          $snapshotListField = 'transitivePeerDependencies'
        } else {
          $explicitId = [regex]::Match($explicitBody, '^id:\s*(?<value>\S.*)\s*$')
          if ($explicitId.Success) {
            $value = [string]$explicitId.Groups['value'].Value.Trim()
            if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
              ($value.StartsWith('"') -and $value.EndsWith('"'))) {
              $value = ConvertFrom-DshPnpmYamlKey -Value $value
            }
            $currentSnapshot.Add('id', $value)
            continue
          }
          $explicitOptional = [regex]::Match($explicitBody, '^optional:\s*(?<value>true|false)\s*$')
          if (-not $explicitOptional.Success) {
            throw "pnpm lock has an unsupported explicit snapshot value: $currentKey"
          }
          $currentSnapshot.Add('optional', [string]$explicitOptional.Groups['value'].Value -ceq 'true')
        }
      }
      continue
    }
    if ($line -cmatch '^  :') { throw "pnpm lock has an unexpected explicit $Section value" }
    $entry = [regex]::Match($line, '^  (?<key>\S.*):\s*\{\}\s*$')
    if (-not $entry.Success) { $entry = [regex]::Match($line, '^  (?<key>\S.*):$') }
    if ($entry.Success) {
      & $finishEntry
      $currentKey = ConvertFrom-DshPnpmYamlKey -Value ([string]$entry.Groups['key'].Value)
      $currentResolution = $null
      $currentResolutionFields = New-DshPnpmOrdinalDictionary
      $nestedResolution = $false
      $currentVersion = ''
      $currentVersionSeen = $false
      $currentPackage = New-DshPnpmOrdinalDictionary
      $packageMapField = ''
      $packageListField = ''
      $packagePeerMetaName = ''
      $currentSnapshot = New-DshPnpmOrdinalDictionary
      $snapshotMapField = ''
      $snapshotListField = ''
      continue
    }
    if ($Section -ceq 'packages' -and $currentKey) {
      $resolution = [regex]::Match($line, '^    resolution:\s*(?<value>\{.*\})\s*$')
      if ($resolution.Success) {
        if ($null -ne $currentResolution -or $currentResolutionFields.Count -gt 0) {
          throw "pnpm package entry duplicates resolution: $currentKey"
        }
        $currentResolution = ConvertFrom-DshPnpmResolution -Value ([string]$resolution.Groups['value'].Value)
        continue
      }
      if ($line -ceq '    resolution:') {
        if ($null -ne $currentResolution -or $currentResolutionFields.Count -gt 0) {
          throw "pnpm package entry duplicates resolution: $currentKey"
        }
        $nestedResolution = $true
        continue
      }
      $version = [regex]::Match($line, '^    version:\s*(?<value>\S.*)\s*$')
      if ($version.Success) {
        if ($currentVersionSeen) { throw "pnpm package entry duplicates version: $currentKey" }
        $currentVersionSeen = $true
        $currentVersion = ConvertFrom-DshPnpmYamlKey -Value ([string]$version.Groups['value'].Value.Trim())
        if ($currentPackage.Contains('version')) { throw "pnpm package $currentKey duplicates field version" }
        $currentPackage.Add('version', $currentVersion)
        $packageMapField = ''
        $packageListField = ''
        $packagePeerMetaName = ''
        continue
      }
      if ($packagePeerMetaName) {
        $metaOptional = [regex]::Match($line, '^        optional:\s*(?<value>true|false)\s*$')
        if ($metaOptional.Success) {
          $meta = $currentPackage['peerDependenciesMeta'][$packagePeerMetaName]
          if ($meta.Contains('optional')) {
            throw "pnpm package $currentKey duplicates peerDependenciesMeta.$packagePeerMetaName.optional"
          }
          $meta.Add('optional', [string]$metaOptional.Groups['value'].Value -ceq 'true')
          continue
        }
      }
      if ($packageMapField) {
        $mappingEntry = [regex]::Match($line, '^      (?<key>\S.*?):\s*(?<value>\S.*)\s*$')
        if ($mappingEntry.Success) {
          $name = ConvertFrom-DshPnpmYamlKey -Value ([string]$mappingEntry.Groups['key'].Value)
          $value = [string]$mappingEntry.Groups['value'].Value.Trim()
          if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
            ($value.StartsWith('"') -and $value.EndsWith('"'))) {
            $value = ConvertFrom-DshPnpmYamlKey -Value $value
          }
          $map = $currentPackage[$packageMapField]
          if ($map.Contains($name)) { throw "pnpm package $currentKey duplicates $packageMapField.$name" }
          $map.Add($name, $value)
          continue
        }
      }
      if ($currentPackage.Contains('peerDependenciesMeta')) {
        $metaEntry = [regex]::Match($line, '^      (?<key>\S.*?):\s*$')
        if ($metaEntry.Success) {
          $name = ConvertFrom-DshPnpmYamlKey -Value ([string]$metaEntry.Groups['key'].Value)
          $metaMap = $currentPackage['peerDependenciesMeta']
          if ($metaMap.Contains($name)) { throw "pnpm package $currentKey duplicates peerDependenciesMeta.$name" }
          $metaMap.Add($name, (New-DshPnpmOrdinalDictionary))
          $packagePeerMetaName = $name
          $packageMapField = ''
          $packageListField = ''
          continue
        }
      }
      if ($packageListField) {
        $listEntry = [regex]::Match($line, '^      -\s+(?<value>\S.*)\s*$')
        if ($listEntry.Success) {
          $value = [string]$listEntry.Groups['value'].Value.Trim()
          if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
            ($value.StartsWith('"') -and $value.EndsWith('"'))) {
            $value = ConvertFrom-DshPnpmYamlKey -Value $value
          }
          $currentPackage[$packageListField].Add($value)
          continue
        }
      }

      $mappingField = [regex]::Match($line, '^    (?<field>engines|peerDependencies):(?:\s*\{\})?\s*$')
      if ($mappingField.Success) {
        $field = [string]$mappingField.Groups['field'].Value
        if ($currentPackage.Contains($field)) { throw "pnpm package $currentKey duplicates field $field" }
        $currentPackage.Add($field, (New-DshPnpmOrdinalDictionary))
        $packageMapField = $field
        $packageListField = ''
        $packagePeerMetaName = ''
        continue
      }
      if ($line -cmatch '^    peerDependenciesMeta:(?:\s*\{\})?\s*$') {
        if ($currentPackage.Contains('peerDependenciesMeta')) {
          throw "pnpm package $currentKey duplicates field peerDependenciesMeta"
        }
        $currentPackage.Add('peerDependenciesMeta', (New-DshPnpmOrdinalDictionary))
        $packageMapField = ''
        $packageListField = ''
        $packagePeerMetaName = ''
        continue
      }
      $listField = [regex]::Match($line, '^    (?<field>bundledDependencies|cpu|libc|os):(?:\s*\[\])?\s*$')
      if ($listField.Success) {
        $field = [string]$listField.Groups['field'].Value
        if ($currentPackage.Contains($field)) { throw "pnpm package $currentKey duplicates field $field" }
        $currentPackage.Add($field, [Collections.Generic.List[string]]::new())
        $packageMapField = ''
        $packageListField = $field
        $packagePeerMetaName = ''
        continue
      }
      if ($line -ceq '    bundledDependencies: true') {
        if ($currentPackage.Contains('bundledDependencies')) {
          throw "pnpm package $currentKey duplicates field bundledDependencies"
        }
        $currentPackage.Add('bundledDependencies', $true)
        $packageMapField = ''
        $packageListField = ''
        $packagePeerMetaName = ''
        continue
      }
      $booleanField = [regex]::Match($line, '^    hasBin:\s*(?<value>true|false)\s*$')
      if ($booleanField.Success) {
        if ($currentPackage.Contains('hasBin')) { throw "pnpm package $currentKey duplicates field hasBin" }
        $currentPackage.Add('hasBin', [string]$booleanField.Groups['value'].Value -ceq 'true')
        $packageMapField = ''
        $packageListField = ''
        $packagePeerMetaName = ''
        continue
      }
      $stringField = [regex]::Match($line, '^    (?<field>deprecated|name):\s*(?<value>\S.*)\s*$')
      if ($stringField.Success) {
        $field = [string]$stringField.Groups['field'].Value
        if ($currentPackage.Contains($field)) { throw "pnpm package $currentKey duplicates field $field" }
        $value = [string]$stringField.Groups['value'].Value.Trim()
        if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
          ($value.StartsWith('"') -and $value.EndsWith('"'))) {
          $value = ConvertFrom-DshPnpmYamlKey -Value $value
        }
        $currentPackage.Add($field, $value)
        $packageMapField = ''
        $packageListField = ''
        $packagePeerMetaName = ''
        continue
      }
      if ($line -cmatch '^    (?<field>[^:\s]+):' -or $line -cmatch '^      \S' -or $line -cmatch '^        \S') {
        throw "pnpm package $currentKey has an unsupported or malformed body line: $line"
      }
      continue
    }
    if ($Section -ceq 'snapshots' -and $currentKey) {
      $mappingField = [regex]::Match($line, '^    (?<field>dependencies|optionalDependencies):(?:\s*\{\})?\s*$')
      if ($mappingField.Success) {
        $field = [string]$mappingField.Groups['field'].Value
        if ($currentSnapshot.Contains($field)) { throw "pnpm snapshot $currentKey duplicates field $field" }
        $currentSnapshot.Add($field, (New-DshPnpmOrdinalDictionary))
        $snapshotMapField = $field
        $snapshotListField = ''
        continue
      }
      if ($line -ceq '    transitivePeerDependencies:') {
        if ($currentSnapshot.Contains('transitivePeerDependencies')) {
          throw "pnpm snapshot $currentKey duplicates field transitivePeerDependencies"
        }
        $currentSnapshot.Add('transitivePeerDependencies', [Collections.Generic.List[string]]::new())
        $snapshotMapField = ''
        $snapshotListField = 'transitivePeerDependencies'
        continue
      }
      $optional = [regex]::Match($line, '^    optional:\s*(?<value>true|false)\s*$')
      if ($optional.Success) {
        if ($currentSnapshot.Contains('optional')) { throw "pnpm snapshot $currentKey duplicates field optional" }
        $currentSnapshot.Add('optional', [string]$optional.Groups['value'].Value -ceq 'true')
        $snapshotMapField = ''
        $snapshotListField = ''
        continue
      }
      $id = [regex]::Match($line, '^    id:\s*(?<value>\S.*)\s*$')
      if ($id.Success) {
        if ($currentSnapshot.Contains('id')) { throw "pnpm snapshot $currentKey duplicates field id" }
        $value = [string]$id.Groups['value'].Value.Trim()
        if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
          ($value.StartsWith('"') -and $value.EndsWith('"'))) {
          $value = ConvertFrom-DshPnpmYamlKey -Value $value
        }
        $currentSnapshot.Add('id', $value)
        $snapshotMapField = ''
        $snapshotListField = ''
        continue
      }
      if ($snapshotMapField) {
        $dependency = [regex]::Match($line, '^      (?<key>\S.*?):\s*(?<value>\S.*)\s*$')
        if ($dependency.Success) {
          $name = ConvertFrom-DshPnpmYamlKey -Value ([string]$dependency.Groups['key'].Value)
          $locator = [string]$dependency.Groups['value'].Value.Trim()
          if (($locator.StartsWith("'") -and $locator.EndsWith("'")) -or
            ($locator.StartsWith('"') -and $locator.EndsWith('"'))) {
            $locator = ConvertFrom-DshPnpmYamlKey -Value $locator
          }
          $map = $currentSnapshot[$snapshotMapField]
          if ($map.Contains($name)) { throw "pnpm snapshot $currentKey duplicates $snapshotMapField.$name" }
          $map.Add($name, $locator)
          continue
        }
      }
      if ($snapshotListField) {
        $peer = [regex]::Match($line, '^      -\s+(?<value>\S.*)\s*$')
        if ($peer.Success) {
          $name = [string]$peer.Groups['value'].Value.Trim()
          if (($name.StartsWith("'") -and $name.EndsWith("'")) -or
            ($name.StartsWith('"') -and $name.EndsWith('"'))) {
            $name = ConvertFrom-DshPnpmYamlKey -Value $name
          }
          $currentSnapshot[$snapshotListField].Add($name)
          continue
        }
      }
      if ($line -cmatch '^    (?<field>[^:\s]+):' -or $line -cmatch '^      \S') {
        throw "pnpm snapshot $currentKey has an unsupported or malformed body line: $line"
      }
    }
  }
  if ($pendingExplicitKey) { throw "pnpm lock has an incomplete explicit $Section key: $pendingExplicitKey" }
  if ($inside -and $currentKey) { & $finishEntry }
  if ($records.Count -eq 0) { throw "pnpm lockfile has no $Section entries: $LockPath" }
  return ,$records
}

function Get-DshPnpmPackageKeyIdentity {
  param([Parameter(Mandatory)][string]$PackageKey)

  $separator = if ($PackageKey.StartsWith('@')) {
    $slash = $PackageKey.IndexOf('/')
    if ($slash -lt 2) { -1 } else { $PackageKey.IndexOf('@', $slash + 1) }
  } else {
    $PackageKey.IndexOf('@')
  }
  if ($separator -le 0 -or $separator -ge $PackageKey.Length - 1) {
    throw "pnpm package key has an unsupported format: $PackageKey"
  }
  $name = $PackageKey.Substring(0, $separator)
  if ($name -cnotmatch '^(?:@[^/@\s]+/[^/@\s]+|[^/@\s]+)$') {
    throw "pnpm package key has an invalid package name: $PackageKey"
  }
  return [pscustomobject]@{
    Locator = $PackageKey.Substring($separator + 1)
    Name = $name
  }
}

function ConvertTo-DshPnpmRelativePath {
  param(
    [Parameter(Mandatory)][string]$Value,
    [Parameter(Mandatory)][string]$Description
  )

  $path = $Value.Trim().Replace('\', '/')
  if (-not $path -or $path -match '[\r\n()]' -or $path.StartsWith('/') -or
    $path -match '^[A-Za-z]:/' -or $path -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
    throw "$Description is not a safe relative pnpm path: $Value"
  }
  return $path
}

function Get-DshPnpmInternalAllowlist {
  param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$InternalPackageAllowlist)

  $byPackageKey = New-DshPnpmOrdinalDictionary
  $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($record in $InternalPackageAllowlist) {
    $nameProperty = $record.PSObject.Properties['Name']
    $pathProperty = $record.PSObject.Properties['RelativePath']
    if ($null -eq $nameProperty -or $null -eq $pathProperty) {
      throw 'internal package allowlist records require Name and RelativePath'
    }
    $name = [string]$nameProperty.Value
    $versionProperty = $record.PSObject.Properties['Version']
    $version = if ($null -eq $versionProperty) { '' } else { [string]$versionProperty.Value }
    $relativePath = ConvertTo-DshPnpmRelativePath -Value ([string]$pathProperty.Value) -Description "internal package $name path"
    $protocolProperty = $record.PSObject.Properties['Protocol']
    $protocol = if ($null -eq $protocolProperty) { '' } else { [string]$protocolProperty.Value }
    if (-not $protocol) { $protocol = 'file' }
    if ($protocol -cnotin @('file', 'link')) { throw "internal package $name has an unsupported protocol: $protocol" }
    if (-not $name -or -not $names.Add($name)) { throw "internal package allowlist has a missing or duplicate name: $name" }
    $packageKey = "$name@${protocol}:$relativePath"
    if ($record.PSObject.Properties['PackageKey']) {
      $declaredKey = [string]$record.PackageKey
      if ($declaredKey -cne $packageKey) { throw "internal package $name has an inconsistent package key" }
    }
    if ($byPackageKey.Contains($packageKey)) { throw "internal package allowlist duplicates identity: $packageKey" }
    $byPackageKey.Add($packageKey, [pscustomobject]@{
      Name = $name
      PackageKey = $packageKey
      Protocol = $protocol
      RelativePath = $relativePath
      Version = $version
    })
  }
  return ,$byPackageKey
}

function Assert-DshPnpmExternalResolution {
  param(
    [Parameter(Mandatory)][object]$Resolution,
    [Parameter(Mandatory)][string]$PackageKey
  )

  foreach ($key in $Resolution.Fields.Keys) {
    if ([string]$key -cnotin @('integrity', 'tarball')) {
      throw "external pnpm package has a non-registry resolution: $PackageKey"
    }
  }
  if ($Resolution.Fields.Contains('integrity') -and [string]$Resolution.Fields['integrity'] -cnotmatch '^sha(?:1|256|384|512)-\S+$') {
    throw "external pnpm package has an invalid integrity: $PackageKey"
  }
  if ($Resolution.Fields.Contains('tarball') -and [string]$Resolution.Fields['tarball'] -match '^(?:file|link):') {
    throw "external pnpm package has a local tarball resolution: $PackageKey"
  }
}

function Assert-DshPnpmInternalPackage {
  param(
    [Parameter(Mandatory)][object]$Allowlisted,
    [Parameter(Mandatory)][object]$Package
  )

  $resolution = $Package.Resolution.Fields
  $locator = "$($Allowlisted.Protocol):$($Allowlisted.RelativePath)"
  $isTarball = $Allowlisted.Protocol -ceq 'file' -and $Allowlisted.RelativePath.EndsWith('.tgz', [StringComparison]::Ordinal)
  if ($isTarball) {
    if (-not $Allowlisted.Version -or [string]$Package.Version -cne [string]$Allowlisted.Version) {
      throw "internal pnpm tarball has the wrong package version: $($Allowlisted.PackageKey)"
    }
    if ($resolution.Count -ne 2 -or -not $resolution.Contains('integrity') -or -not $resolution.Contains('tarball') -or
      [string]$resolution['integrity'] -cnotmatch '^sha(?:1|256|384|512)-\S+$' -or
      [string]$resolution['tarball'] -cne $locator) {
      throw "internal pnpm tarball has an unexpected resolution: $($Allowlisted.PackageKey)"
    }
    return
  }

  if ($Allowlisted.Version -and [string]$Package.Version -cne [string]$Allowlisted.Version) {
    throw "internal pnpm directory has the wrong package version: $($Allowlisted.PackageKey)"
  }
  if ($resolution.Count -ne 2 -or -not $resolution.Contains('directory') -or -not $resolution.Contains('type') -or
    [string]$resolution['directory'] -cne [string]$Allowlisted.RelativePath -or [string]$resolution['type'] -cne 'directory') {
    throw "internal pnpm directory has an unexpected resolution: $($Allowlisted.PackageKey)"
  }
}

function Get-DshPnpmRuntimeLockModel {
  param(
    [Parameter(Mandatory)][string]$LockPath,
    [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$InternalPackageAllowlist
  )

  $packages = Get-DshPnpmLockSectionEntries -LockPath $LockPath -Section packages
  $snapshots = Get-DshPnpmLockSectionEntries -LockPath $LockPath -Section snapshots
  $allowedInternal = Get-DshPnpmInternalAllowlist -InternalPackageAllowlist $InternalPackageAllowlist
  $internalPackageKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $externalPackages = New-DshPnpmOrdinalDictionary

  foreach ($packageKeyValue in $packages.Keys) {
    $packageKey = [string]$packageKeyValue
    $package = $packages[$packageKey]
    $identity = Get-DshPnpmPackageKeyIdentity -PackageKey $packageKey
    $isLocal = [string]$identity.Locator -match '^(?:file|link):'
    if ($isLocal) {
      if (-not $allowedInternal.Contains($packageKey)) { throw "pnpm lock contains an unknown local package: $packageKey" }
      $allowlisted = $allowedInternal[$packageKey]
      if ([string]$identity.Name -cne [string]$allowlisted.Name) { throw "internal pnpm package has the wrong name: $packageKey" }
      Assert-DshPnpmInternalPackage -Allowlisted $allowlisted -Package $package
      [void]$internalPackageKeys.Add($packageKey)
      continue
    }
    Assert-DshPnpmExternalResolution -Resolution $package.Resolution -PackageKey $packageKey
    $externalPackages.Add($packageKey, $package)
  }
  if ($internalPackageKeys.Count -ne $allowedInternal.Count) {
    throw "pnpm lock has $($internalPackageKeys.Count) allowlisted local packages, expected $($allowedInternal.Count)"
  }

  $referencedPackages = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $externalRecords = [Collections.Generic.List[object]]::new()
  $internalRecords = [Collections.Generic.List[object]]::new()
  foreach ($snapshotKeyValue in $snapshots.Keys) {
    $snapshotKey = [string]$snapshotKeyValue
    $snapshot = $snapshots[$snapshotKey]
    $packageKey = if ($packages.Contains($snapshotKey)) {
      $snapshotKey
    } else {
      [regex]::Replace($snapshotKey, '\(.*$', '')
    }
    if (-not $packages.Contains($packageKey)) { throw "pnpm snapshot has no package record: $snapshotKey" }
    [void]$referencedPackages.Add($packageKey)
    if ($internalPackageKeys.Contains($packageKey)) {
      $allowlisted = $allowedInternal[$packageKey]
      $internalRecords.Add([pscustomobject][ordered]@{
        snapshotKey = $snapshotKey
        packageKey = $packageKey
        packageName = [string]$allowlisted.Name
        packageVersion = [string]$allowlisted.Version
        packageJson = [string]$packages[$packageKey].PackageJson
        snapshotJson = [string]$snapshot.SnapshotJson
      })
      continue
    }
    if (-not $externalPackages.Contains($packageKey)) { throw "pnpm snapshot has an unclassified package record: $snapshotKey" }
    $identity = Get-DshPnpmPackageKeyIdentity -PackageKey $packageKey
    $externalRecords.Add([pscustomobject][ordered]@{
      snapshotKey = $snapshotKey
      packageKey = $packageKey
      packageName = [string]$identity.Name
      packageVersion = [string]$identity.Locator
      packageJson = [string]$externalPackages[$packageKey].PackageJson
      resolutionJson = [string]$externalPackages[$packageKey].Resolution.Json
      snapshotJson = [string]$snapshot.SnapshotJson
    })
  }
  foreach ($packageKeyValue in $packages.Keys) {
    $packageKey = [string]$packageKeyValue
    if (-not $referencedPackages.Contains($packageKey)) { throw "pnpm package has no runtime snapshot: $packageKey" }
  }
  return [pscustomobject]@{
    ExternalRecords = @($externalRecords | Sort-Object snapshotKey, packageKey)
    InternalRecords = @($internalRecords | Sort-Object packageName, snapshotKey)
    InternalCount = $internalPackageKeys.Count
  }
}

function Get-DshPnpmExternalRuntimeResolutions {
  param(
    [Parameter(Mandatory)][string]$LockPath,
    [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$InternalPackageAllowlist
  )

  $model = Get-DshPnpmRuntimeLockModel -LockPath $LockPath -InternalPackageAllowlist $InternalPackageAllowlist
  return @($model.ExternalRecords)
}

function Assert-DshPnpmLockMatchesRuntimeResolutions {
  param(
    [Parameter(Mandatory)][string]$CandidateLockPath,
    [Parameter(Mandatory)][object]$ExpectedConsumerLockControl,
    [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$ExpectedResolutions,
    [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$ExpectedInternalSnapshots,
    [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$InternalPackageAllowlist
  )

  $candidateControl = Get-DshPnpmConsumerLockControl -LockPath $CandidateLockPath
  $expectedControl = ConvertTo-DshPnpmConsumerLockControl `
    -Control $ExpectedConsumerLockControl `
    -Description 'official consumer lock control'
  if ([string]$candidateControl.Json -cne [string]$expectedControl.Json) {
    throw 'runtime lock control differs from the verified consumer lock control'
  }
  $model = Get-DshPnpmRuntimeLockModel `
    -LockPath $CandidateLockPath `
    -InternalPackageAllowlist $InternalPackageAllowlist
  $candidate = @($model.ExternalRecords)
  $candidateBySnapshot = New-DshPnpmOrdinalDictionary
  foreach ($record in $candidate) { $candidateBySnapshot.Add([string]$record.snapshotKey, $record) }

  $expectedBySnapshot = New-DshPnpmOrdinalDictionary
  foreach ($record in $ExpectedResolutions) {
    $snapshotKey = [string]$record.snapshotKey
    $packageKey = [string]$record.packageKey
    $packageName = [string]$record.packageName
    $packageVersion = [string]$record.packageVersion
    if (-not $snapshotKey -or $expectedBySnapshot.Contains($snapshotKey)) {
      throw "official runtime resolutions contain a missing or duplicate snapshot key: $snapshotKey"
    }
    if ($snapshotKey -cne $packageKey -and -not $snapshotKey.StartsWith("$packageKey(", [StringComparison]::Ordinal)) {
      throw "official runtime snapshot does not identify its package record: $snapshotKey"
    }
    $identity = Get-DshPnpmPackageKeyIdentity -PackageKey $packageKey
    if ([string]$identity.Locator -match '^(?:file|link):' -or [string]$identity.Name -cne $packageName -or
      [string]$identity.Locator -cne $packageVersion) {
      throw "official runtime resolution has inconsistent package identity: $snapshotKey"
    }
    $resolution = ConvertTo-DshPnpmExpectedResolution `
      -Resolution $record.resolution `
      -Description "official runtime resolution $snapshotKey"
    Assert-DshPnpmExternalResolution -Resolution $resolution -PackageKey $packageKey
    $packageProperty = $record.PSObject.Properties['package']
    if ($null -eq $packageProperty) { throw "official runtime resolution has no package body: $snapshotKey" }
    $package = ConvertTo-DshPnpmPackageBody `
      -Package $packageProperty.Value `
      -Description "official runtime package $packageKey"
    $snapshotProperty = $record.PSObject.Properties['snapshot']
    if ($null -eq $snapshotProperty) { throw "official runtime resolution has no snapshot body: $snapshotKey" }
    $snapshot = ConvertTo-DshPnpmSnapshotBody `
      -Snapshot $snapshotProperty.Value `
      -Description "official runtime snapshot $snapshotKey"
    $expectedBySnapshot.Add($snapshotKey, [pscustomobject]@{
      PackageKey = $packageKey
      PackageName = $packageName
      PackageVersion = $packageVersion
      PackageJson = [string]$package.Json
      ResolutionJson = [string]$resolution.Json
      SnapshotJson = [string]$snapshot.Json
    })
  }

  foreach ($record in $candidate) {
    $snapshotKey = [string]$record.snapshotKey
    if (-not $expectedBySnapshot.Contains($snapshotKey)) {
      throw "runtime lock has an external snapshot absent from the official production closure: $snapshotKey"
    }
    $expected = $expectedBySnapshot[$snapshotKey]
    if ($expected.PackageKey -cne [string]$record.packageKey -or
      $expected.PackageName -cne [string]$record.packageName -or
      $expected.PackageVersion -cne [string]$record.packageVersion) {
      throw "runtime package identity differs from the official production closure: $snapshotKey"
    }
    if ($expected.PackageJson -cne [string]$record.packageJson) {
      throw "runtime package metadata differs from the official production closure: $snapshotKey"
    }
    if ($expected.ResolutionJson -cne [string]$record.resolutionJson -or
      $expected.SnapshotJson -cne [string]$record.snapshotJson) {
      throw "runtime package resolution differs from the official production closure: $snapshotKey"
    }
  }
  foreach ($snapshotKeyValue in $expectedBySnapshot.Keys) {
    $snapshotKey = [string]$snapshotKeyValue
    if (-not $candidateBySnapshot.Contains($snapshotKey)) {
      throw "runtime lock is missing an official production snapshot: $snapshotKey"
    }
  }

  $expectedInternalBySnapshot = New-DshPnpmOrdinalDictionary
  foreach ($record in $ExpectedInternalSnapshots) {
    $snapshotKey = [string]$record.snapshotKey
    $packageKey = [string]$record.packageKey
    $packageName = [string]$record.packageName
    $packageVersion = [string]$record.packageVersion
    if (-not $snapshotKey -or $expectedInternalBySnapshot.Contains($snapshotKey)) {
      throw "official runtime internal snapshots contain a missing or duplicate key: $snapshotKey"
    }
    if ($snapshotKey -cne $packageKey -and -not $snapshotKey.StartsWith("$packageKey(", [StringComparison]::Ordinal)) {
      throw "official runtime internal snapshot does not identify its package record: $snapshotKey"
    }
    $identity = Get-DshPnpmPackageKeyIdentity -PackageKey $packageKey
    if ([string]$identity.Locator -cnotmatch '^(?:file|link):' -or [string]$identity.Name -cne $packageName) {
      throw "official runtime internal snapshot has inconsistent package identity: $snapshotKey"
    }
    $snapshotProperty = $record.PSObject.Properties['snapshot']
    if ($null -eq $snapshotProperty) { throw "official runtime internal snapshot has no body: $snapshotKey" }
    $snapshot = ConvertTo-DshPnpmSnapshotBody `
      -Snapshot $snapshotProperty.Value `
      -Description "official runtime internal snapshot $snapshotKey"
    $packageProperty = $record.PSObject.Properties['package']
    if ($null -eq $packageProperty) { throw "official runtime internal snapshot has no package body: $snapshotKey" }
    $package = ConvertTo-DshPnpmPackageBody `
      -Package $packageProperty.Value `
      -Description "official runtime internal package $packageKey"
    $expectedInternalBySnapshot.Add($snapshotKey, [pscustomobject]@{
      PackageKey = $packageKey
      PackageName = $packageName
      PackageVersion = $packageVersion
      PackageJson = [string]$package.Json
      SnapshotJson = [string]$snapshot.Json
    })
  }
  $candidateInternalBySnapshot = New-DshPnpmOrdinalDictionary
  foreach ($record in $model.InternalRecords) {
    $snapshotKey = [string]$record.snapshotKey
    if ($candidateInternalBySnapshot.Contains($snapshotKey)) { throw "runtime lock duplicates internal snapshot: $snapshotKey" }
    $candidateInternalBySnapshot.Add($snapshotKey, $record)
    if (-not $expectedInternalBySnapshot.Contains($snapshotKey)) {
      throw "runtime lock has an internal snapshot absent from the official production closure: $snapshotKey"
    }
    $expected = $expectedInternalBySnapshot[$snapshotKey]
    if ($expected.PackageKey -cne [string]$record.packageKey -or
      $expected.PackageName -cne [string]$record.packageName -or
      $expected.PackageVersion -cne [string]$record.packageVersion) {
      throw "runtime internal package identity differs from the official production closure: $snapshotKey"
    }
    if ($expected.PackageJson -cne [string]$record.packageJson) {
      throw "runtime internal package metadata differs from the official production closure: $snapshotKey"
    }
    if ($expected.SnapshotJson -cne [string]$record.snapshotJson) {
      throw "runtime internal snapshot differs from the official production closure: $snapshotKey"
    }
  }
  foreach ($snapshotKeyValue in $expectedInternalBySnapshot.Keys) {
    $snapshotKey = [string]$snapshotKeyValue
    if (-not $candidateInternalBySnapshot.Contains($snapshotKey)) {
      throw "runtime lock is missing an official production internal snapshot: $snapshotKey"
    }
  }
  if ($expectedInternalBySnapshot.Count -ne $model.InternalCount) {
    throw "official runtime has $($expectedInternalBySnapshot.Count) internal snapshots, expected $($model.InternalCount)"
  }
  return [pscustomobject]@{
    CandidateCount = $candidate.Count
    InternalCount = $model.InternalCount
    OfficialCount = $expectedBySnapshot.Count
  }
}
