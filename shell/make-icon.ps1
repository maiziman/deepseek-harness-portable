# Generates shell\icon.ico (256x256, PNG-compressed single entry) for the
# desktop shell. Runs on Windows with System.Drawing available (pwsh).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$out = Join-Path $PSScriptRoot 'icon.ico'
$size = 256
$bmp = [System.Drawing.Bitmap]::new($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)

  $r = 44
  $d = $r * 2
  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  try {
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($size - $d, 0, $d, $d, 270, 90)
    $path.AddArc($size - $d, $size - $d, $d, $d, 0, 90)
    $path.AddArc(0, $size - $d, $d, $d, 90, 90)
    $path.CloseFigure()

    $rect = [System.Drawing.Rectangle]::new(0, 0, $size, $size)
    $brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
      $rect,
      [System.Drawing.Color]::FromArgb(255, 77, 107, 254),
      [System.Drawing.Color]::FromArgb(255, 11, 19, 42),
      45)
    $g.FillPath($brush, $path)

    $font = [System.Drawing.Font]::new('Segoe UI', 92, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = [System.Drawing.StringFormat]::new()
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('DSH', $font, [System.Drawing.Brushes]::White, [System.Drawing.RectangleF]::new(0, 12, $size, $size), $sf)
  } finally {
    $path.Dispose()
  }

  $pngStream = [System.IO.MemoryStream]::new()
  try {
    $bmp.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $pngStream.ToArray()

    # ICO container: ICONDIR + one ICONDIRENTRY (width/height 0 = 256) + PNG data.
    $fs = [System.IO.File]::Create($out)
    $bw = [System.IO.BinaryWriter]::new($fs)
    try {
      $bw.Write([byte]0); $bw.Write([byte]0)          # reserved
      $bw.Write([byte]1); $bw.Write([byte]1)          # type icon, count 1
      $bw.Write([byte]0); $bw.Write([byte]0)          # width 256
      $bw.Write([byte]0); $bw.Write([byte]0)          # height 256
      $bw.Write([byte]0); $bw.Write([byte]0)          # palette
      $bw.Write([byte]0); $bw.Write([byte]0)          # reserved
      $bw.Write([uint16]1); $bw.Write([uint16]32)     # planes, bpp
      $bw.Write([uint32]$png.Length)
      $bw.Write([uint32]22)                           # data offset
      $bw.Write($png)
    } finally {
      $bw.Dispose(); $fs.Dispose()
    }
    Write-Output "icon written: $out ($($png.Length + 22) bytes)"
  } finally {
    $pngStream.Dispose()
  }
} finally {
  $g.Dispose(); $bmp.Dispose()
}
