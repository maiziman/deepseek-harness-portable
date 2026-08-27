# Generates a PNG-compressed, multi-size Windows icon from app-icon.png.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$sourcePath = Join-Path $PSScriptRoot 'app-icon.png'
$out = Join-Path $PSScriptRoot 'icon.ico'
$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
  throw "desktop icon source missing: $sourcePath"
}

$source = [System.Drawing.Bitmap]::new($sourcePath)
$pngImages = @()
try {
  if ($source.Width -ne $source.Height -or $source.Width -lt 256) {
    throw "desktop icon source must be square and at least 256 px: $sourcePath"
  }

  $hasTransparentPixel = $false
  $hasOpaquePixel = $false
  for ($y = 0; $y -lt $source.Height -and -not ($hasTransparentPixel -and $hasOpaquePixel); $y += 1) {
    for ($x = 0; $x -lt $source.Width; $x += 1) {
      $alpha = $source.GetPixel($x, $y).A
      if ($alpha -eq 0) { $hasTransparentPixel = $true }
      if ($alpha -eq 255) { $hasOpaquePixel = $true }
      if ($hasTransparentPixel -and $hasOpaquePixel) { break }
    }
  }
  if (-not $hasTransparentPixel -or -not $hasOpaquePixel) {
    throw "desktop icon source must contain transparent and opaque pixels: $sourcePath"
  }

  foreach ($size in $sizes) {
    $bitmap = [System.Drawing.Bitmap]::new(
      $size,
      $size,
      [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.Clear([System.Drawing.Color]::Transparent)
      $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
      $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
      $graphics.DrawImage($source, 0, 0, $size, $size)

      $stream = [System.IO.MemoryStream]::new()
      try {
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngImages += ,([byte[]]$stream.ToArray())
      } finally {
        $stream.Dispose()
      }
    } finally {
      $graphics.Dispose()
      $bitmap.Dispose()
    }
  }
} finally {
  $source.Dispose()
}

$file = [System.IO.File]::Create($out)
$writer = [System.IO.BinaryWriter]::new($file)
try {
  $writer.Write([uint16]0)
  $writer.Write([uint16]1)
  $writer.Write([uint16]$sizes.Count)

  $offset = 6 + (16 * $sizes.Count)
  for ($index = 0; $index -lt $sizes.Count; $index += 1) {
    $size = $sizes[$index]
    $png = [byte[]]$pngImages[$index]
    $dimension = if ($size -eq 256) { [byte]0 } else { [byte]$size }
    $writer.Write($dimension)
    $writer.Write($dimension)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$png.Length)
    $writer.Write([uint32]$offset)
    $offset += $png.Length
  }

  foreach ($png in $pngImages) {
    $writer.Write([byte[]]$png)
  }
} finally {
  $writer.Dispose()
  $file.Dispose()
}

Write-Output "icon written: $out ($($sizes.Count) sizes, $((Get-Item $out).Length) bytes)"
