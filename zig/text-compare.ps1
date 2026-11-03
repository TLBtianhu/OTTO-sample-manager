# Render OTTO and System.Drawing ClearType offscreen, then compose a 1x/4x audit.
# No HWND, no screen capture, no focus change. ASCII only for PowerShell 5.1.
[CmdletBinding()]
param(
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe',
  [string]$OutDir = '',
  [ValidateSet('dark', 'light')][string]$Theme = 'dark'
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root ('..\artifacts\text-cleartype\' + $Theme) }
$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$otto = Join-Path $OutDir 'otto.png'
$native = Join-Path $OutDir 'native-system-drawing.png'
Push-Location (Join-Path $root 'app')
try {
  $probeArgs = @()
  if ($Theme -eq 'light') { $probeArgs = @('light') }
  $ErrorActionPreference = 'Continue'
  $probeLines = @(& $Zig build text-compare -- $otto @probeArgs 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
  })
  $probeExit = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($probeExit -ne 0) { throw "text-compare exit $probeExit" }
  [IO.File]::WriteAllLines((Join-Path $OutDir 'probe.log'), [string[]]$probeLines, [Text.UTF8Encoding]::new($false))
  $probeLines | Write-Output
} finally {
  Pop-Location
}

Add-Type -AssemblyName System.Drawing
$bg = if ($Theme -eq 'dark') { [Drawing.Color]::FromArgb(255, 28, 28, 30) } else { [Drawing.Color]::FromArgb(255, 245, 245, 247) }
$fg = if ($Theme -eq 'dark') { [Drawing.Color]::FromArgb(255, 245, 245, 247) } else { [Drawing.Color]::FromArgb(255, 28, 28, 30) }
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

function Get-Luma([Drawing.Color]$Color) {
  return 0.2126 * $Color.R + 0.7152 * $Color.G + 0.0722 * $Color.B
}
function Get-InkStats([string]$Path) {
  $im = [Drawing.Bitmap]::new($Path)
  $bgLum = Get-Luma $bg; $fgLum = Get-Luma $fg
  $sum = 0.0; $count = 0; $strong = 0
  for ($y = 0; $y -lt 24; $y++) {
    for ($x = 0; $x -lt 180; $x++) {
      $lum = Get-Luma ($im.GetPixel($x, $y))
      $cov = [Math]::Max([double]0, [Math]::Min([double]1, ($lum - $bgLum) / ($fgLum - $bgLum)))
      if ($cov -gt 0.05) {
        $sum += $cov; $count++
        if ($cov -gt 0.8) { $strong++ }
      }
    }
  }
  $im.Dispose()
  return @{ Sum = $sum; Pixels = $count; Strong = if ($count -gt 0) { $strong / $count } else { 0 } }
}
function Get-ErrorStats([string]$Actual, [string]$Expected) {
  $a = [Drawing.Bitmap]::new($Actual); $b = [Drawing.Bitmap]::new($Expected)
  $best = @{ MAE = [double]::MaxValue; RGB = 0.0; DX = 0; DY = 0 }
  for ($dy = -1; $dy -le 1; $dy++) {
    for ($dx = -2; $dx -le 2; $dx++) {
      $sum = 0.0; $rgb = 0.0; $n = 0
      for ($y = 0; $y -lt 24; $y++) {
        $ny = $y + $dy; if ($ny -lt 0 -or $ny -ge 24) { continue }
        for ($x = 0; $x -lt 180; $x++) {
          $nx = $x + $dx; if ($nx -lt 0 -or $nx -ge 180) { continue }
          $ca = $a.GetPixel($x, $y); $cb = $b.GetPixel($nx, $ny)
          $sum += [Math]::Abs((Get-Luma $ca) - (Get-Luma $cb))
          $rgb += ([Math]::Abs($ca.R - $cb.R) + [Math]::Abs($ca.G - $cb.G) + [Math]::Abs($ca.B - $cb.B)) / 3
          $n++
        }
      }
      $mae = $sum / $n
      if ($mae -lt $best.MAE) { $best = @{ MAE = $mae; RGB = $rgb / $n; DX = $dx; DY = $dy } }
    }
  }
  $a.Dispose(); $b.Dispose()
  return $best
}

$canvas = [Drawing.Bitmap]::new(760, 300)
$g = [Drawing.Graphics]::FromImage($canvas)
$g.Clear($bg)
$g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
$labelFont = [Drawing.Font]::new('Segoe UI', [float]10, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$labelBrush = [Drawing.SolidBrush]::new($fg)
$files = @($otto, $native)
$labels = @('OTTO GDI Natural + linked scale + polarity gamma', 'System.Drawing ClearType grid-fit')
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
$a = Get-InkStats $otto; $b = Get-InkStats $native; $errorStats = Get-ErrorStats $otto $native
$metrics = [ordered]@{
  sample = $sample; theme = $Theme; font = 'Segoe UI 13px at 96 DPI'; area = '180x24, whole canvas'
  rendering = 'small em GDI_NATURAL; linked UI optical scale; polarity gamma light=0.78 dark=1.28'
  otto_coverage = [Math]::Round($a.Sum, 4); native_coverage = [Math]::Round($b.Sum, 4)
  otto_strong = [Math]::Round($a.Strong, 4); native_strong = [Math]::Round($b.Strong, 4)
  mae_luma_255 = [Math]::Round($errorStats.MAE, 4); mae_rgb_255 = [Math]::Round($errorStats.RGB, 4)
  best_dx = $errorStats.DX; best_dy = $errorStats.DY
}
[IO.File]::WriteAllText((Join-Path $OutDir 'metrics.json'), ($metrics | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Write-Output ('text-compare: {0} MAE={1:N4}/255 RGB={2:N4}; coverage={3:N2}/{4:N2}; dx={5},dy={6}' -f
  $Theme, $errorStats.MAE, $errorStats.RGB, $a.Sum, $b.Sum, $errorStats.DX, $errorStats.DY)
Write-Output "text-compare: PASS $comparison"
