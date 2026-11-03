# Render OTTO and System.Drawing ClearType offscreen, then compose a 1x/4x audit.
# No HWND, no screen capture, no focus change. ASCII only for PowerShell 5.1.
[CmdletBinding()]
param(
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe',
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root '..\artifacts\text-cleartype\after' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$otto = Join-Path $OutDir 'otto.png'
$native = Join-Path $OutDir 'native-system-drawing.png'
Push-Location (Join-Path $root 'app')
try {
  & $Zig build text-compare -- $otto
  if ($LASTEXITCODE -ne 0) { throw "text-compare exit $LASTEXITCODE" }
} finally {
  Pop-Location
}

Add-Type -AssemblyName System.Drawing
$bg = [Drawing.Color]::FromArgb(255, 28, 28, 30)
$fg = [Drawing.Color]::FromArgb(255, 245, 245, 247)
$bmp = [Drawing.Bitmap]::new(360, 48)
$g = [Drawing.Graphics]::FromImage($bmp)
$font = [Drawing.Font]::new('Segoe UI', [float]13, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$brush = [Drawing.SolidBrush]::new($fg)
$fmt = [Drawing.StringFormat]::GenericTypographic
$g.Clear($bg)
$g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$sample = 'Sample 0001 ' + [char]0x00B7 + ' ' + [char]0x91C7 + [char]0x6837 + [char]0x7BA1 + [char]0x7406 + ' 13px'
$g.DrawString($sample, $font, $brush, [float]0, [float]0, $fmt)
$bmp.Save($native, [Drawing.Imaging.ImageFormat]::Png)
$fmt.Dispose(); $brush.Dispose(); $font.Dispose(); $g.Dispose(); $bmp.Dispose()

function Get-InkStats([string]$Path) {
  $im = [Drawing.Bitmap]::new($Path)
  $sum = 0.0; $count = 0; $strong = 0
  for ($y = 0; $y -lt 24; $y++) {
    for ($x = 0; $x -lt 180; $x++) {
      $c = $im.GetPixel($x, $y)
      $lum = 0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B
      $cov = [Math]::Max([double]0, [Math]::Min([double]1, ($lum - 28) / 217))
      if ($cov -gt 0.05) {
        $sum += $cov; $count++
        if ($cov -gt 0.8) { $strong++ }
      }
    }
  }
  $im.Dispose()
  return @{ Sum = $sum; Pixels = $count; Strong = $strong }
}

$canvas = [Drawing.Bitmap]::new(760, 300)
$g = [Drawing.Graphics]::FromImage($canvas)
$g.Clear($bg)
$g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
$labelFont = [Drawing.Font]::new('Segoe UI', [float]10, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$labelBrush = [Drawing.SolidBrush]::new($fg)
$files = @($otto, $native)
$labels = @('OTTO DirectWrite small-em grid-fit', 'System.Drawing ClearType grid-fit')
for ($i = 0; $i -lt 2; $i++) {
  $im = [Drawing.Bitmap]::new($files[$i])
  $top = $i * 145
  $g.DrawString($labels[$i], $labelFont, $labelBrush, [float]5, [float]($top + 5))
  $g.DrawImageUnscaled($im, 0, $top + 25)
  $dest = [Drawing.Rectangle]::new(20, $top + 55, 720, 96)
  $src = [Drawing.Rectangle]::new(0, 0, 180, 24)
  $g.DrawImage($im, $dest, $src, [Drawing.GraphicsUnit]::Pixel)
  $im.Dispose()
}
$comparison = Join-Path $OutDir 'comparison.png'
$canvas.Save($comparison, [Drawing.Imaging.ImageFormat]::Png)
$labelBrush.Dispose(); $labelFont.Dispose(); $g.Dispose(); $canvas.Dispose()
$a = Get-InkStats $otto
$b = Get-InkStats $native
Write-Output ('text-compare: OTTO coverage={0:N2} strong={1:N3}; native coverage={2:N2} strong={3:N3}' -f
  $a.Sum, ($a.Strong / $a.Pixels), $b.Sum, ($b.Strong / $b.Pixels))
Write-Output "text-compare: PASS $comparison"
