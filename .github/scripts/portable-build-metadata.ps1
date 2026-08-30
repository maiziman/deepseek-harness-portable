# Remove non-executable package-manager and source-region annotations that can
# retain a build machine's absolute paths in an otherwise relocatable package.
Set-StrictMode -Version Latest

$script:DshAbsoluteSourceRegionPattern = '(?m)^[ \t]*//#region \\0dsh-(?:css|global-css|inline-css):(?:[A-Za-z]:[\\/]|/)'
$script:DshSourceRegionRewritePattern = '(?m)^(?<prefix>[ \t]*//#region \\0dsh-(?:css|global-css|inline-css):)(?:[A-Za-z]:[\\/]|/)[^\r\n]*?[\\/](?<relative>packages[\\/][^\r\n]+)(?<ending>\r?)$'
$script:DshPnpmShimTargetPattern = '(?m)^# cmd-shim-target=[^\r\n]*(?:\r?\n|$)'

function Get-DshPortableMetadataFiles([string]$ModulesRoot) {
  if (-not (Test-Path -LiteralPath $ModulesRoot -PathType Container)) { return @() }
  $files = [Collections.Generic.List[IO.FileInfo]]::new()
  foreach ($bundle in @(Get-ChildItem -LiteralPath $ModulesRoot -Recurse -File -Filter 'client.js')) {
    $files.Add($bundle)
  }
  foreach ($binDirectory in @(Get-ChildItem -LiteralPath $ModulesRoot -Recurse -Directory -Filter '.bin')) {
    foreach ($shim in @(Get-ChildItem -LiteralPath $binDirectory.FullName -File)) {
      $files.Add($shim)
    }
  }
  return @($files | Sort-Object FullName -Unique)
}

function Normalize-DshPortableBuildMetadata([string]$ModulesRoot) {
  $sourceAnnotations = 0
  $shimAnnotations = 0
  $sourceEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    return $match.Groups['prefix'].Value + $match.Groups['relative'].Value.Replace('\', '/') + $match.Groups['ending'].Value
  }
  foreach ($file in @(Get-DshPortableMetadataFiles $ModulesRoot)) {
    $text = [IO.File]::ReadAllText($file.FullName)
    $sourceMatches = [regex]::Matches($text, $script:DshSourceRegionRewritePattern)
    $shimMatches = [regex]::Matches($text, $script:DshPnpmShimTargetPattern)
    if ($sourceMatches.Count -eq 0 -and $shimMatches.Count -eq 0) { continue }
    $updated = [regex]::Replace($text, $script:DshSourceRegionRewritePattern, $sourceEvaluator)
    $updated = [regex]::Replace($updated, $script:DshPnpmShimTargetPattern, '')
    [IO.File]::WriteAllText($file.FullName, $updated, [Text.UTF8Encoding]::new($false))
    $sourceAnnotations += $sourceMatches.Count
    $shimAnnotations += $shimMatches.Count
  }
  return [pscustomobject]@{
    SourceAnnotations = $sourceAnnotations
    ShimAnnotations = $shimAnnotations
  }
}

function Assert-DshPortableBuildMetadataClean([string]$ModulesRoot) {
  foreach ($file in @(Get-DshPortableMetadataFiles $ModulesRoot)) {
    $text = [IO.File]::ReadAllText($file.FullName)
    if ([regex]::IsMatch($text, $script:DshAbsoluteSourceRegionPattern)) {
      throw "portable package contains an absolute generated source annotation: $($file.FullName)"
    }
    if ([regex]::IsMatch($text, $script:DshPnpmShimTargetPattern)) {
      throw "portable package contains a package-manager build target annotation: $($file.FullName)"
    }
  }
}

function Get-DshPortableSensitivePathPatterns([string[]]$SensitivePaths) {
  $patterns = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($path in $SensitivePaths) {
    if (-not $path) { continue }
    $full = [IO.Path]::GetFullPath($path).TrimEnd([char]'\', [char]'/')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd([char]'\', [char]'/')
    if (-not $full -or $full -ceq $root) { throw "refusing to scan for an unsafe broad path: $path" }
    [void]$roots.Add($full)
  }
  $minimalRoots = [Collections.Generic.List[string]]::new()
  foreach ($full in @($roots | Sort-Object Length, { $_ })) {
    $isChild = $false
    foreach ($parent in $minimalRoots) {
      if ($full.StartsWith($parent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($parent + [IO.Path]::AltDirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        $isChild = $true
        break
      }
    }
    if ($isChild) { continue }
    $minimalRoots.Add($full)
    $slash = $full.Replace('\', '/')
    $backslash = $full.Replace('/', '\')
    foreach ($variant in @(
      $slash,
      $backslash,
      $backslash.Replace('\', '\\'),
      ([Uri]$full).AbsoluteUri.TrimEnd('/'),
      [Uri]::EscapeDataString($slash),
      [Uri]::EscapeDataString($backslash),
      $slash.Replace(' ', '%20'),
      $backslash.Replace(' ', '%20')
    )) {
      if ($variant.Length -ge 8) { [void]$patterns.Add($variant) }
    }
  }
  return @($patterns | Sort-Object)
}

function Assert-DshPortableTreeHasNoSensitivePaths {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string[]]$SensitivePaths
  )

  $patterns = @(Get-DshPortableSensitivePathPatterns -SensitivePaths $SensitivePaths)
  if ($patterns.Count -eq 0) { throw 'portable path scan has no sensitive path patterns' }
  $bytePatterns = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($pattern in $patterns) {
    foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode, [Text.Encoding]::BigEndianUnicode)) {
      $encoded = [Text.Encoding]::Latin1.GetString($encoding.GetBytes($pattern))
      if ($encoded) { [void]$bytePatterns.Add($encoded) }
    }
  }
  $maxPatternLength = @($bytePatterns | ForEach-Object Length | Measure-Object -Maximum).Maximum
  $buffer = [char[]]::new(1024 * 1024)
  $fileCount = 0
  foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
    $fileCount++
    $reader = [IO.StreamReader]::new($file.FullName, [Text.Encoding]::Latin1, $false, 1024 * 1024)
    try {
      $carry = ''
      while (($read = $reader.ReadBlock($buffer, 0, $buffer.Length)) -gt 0) {
        $chunk = $carry + [string]::new($buffer, 0, $read)
        foreach ($pattern in $bytePatterns) {
          if ($chunk.IndexOf($pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "portable package contains a build-machine path in $($file.FullName)"
          }
        }
        $carryLength = [Math]::Min($maxPatternLength - 1, $chunk.Length)
        $carry = if ($carryLength -gt 0) { $chunk.Substring($chunk.Length - $carryLength) } else { '' }
      }
    } finally {
      $reader.Dispose()
    }
  }
  return [pscustomobject]@{
    Files = $fileCount
    Patterns = $patterns.Count
  }
}
