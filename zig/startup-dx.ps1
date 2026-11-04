# Verify PE version/icon pixels and a real hidden window's big/small icons.
# Crash MessageBox checks are opt-in (-IncludeCrash); the default never shows one.
# All data lives below TEMP; normal startup uses nanoui's hidden snapshot mode.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.

[CmdletBinding()]
param(
  [string]$Exe = '',
  [string]$Helper = '',
  [string]$OutDir = '',
  [switch]$IncludeCrash
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $root 'app\zig-out\bin\otto-lite.exe' }
if (-not $Helper) { $Helper = Join-Path $root 'app\zig-out\bin\otto-thumb-host.exe' }
if (-not $OutDir) { $OutDir = Join-Path $root 'out\startup-dx' }
$Exe = [IO.Path]::GetFullPath($Exe)
$Helper = [IO.Path]::GetFullPath($Helper)
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $Exe)) { throw "missing exe: $Exe" }
if (-not (Test-Path -LiteralPath $Helper)) { throw "missing helper: $Helper" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$work = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'otto-startup-dx-accept'))
$tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
if ([IO.Path]::GetDirectoryName($work).TrimEnd('\') -ne $tempRoot) {
  throw "unsafe test directory: $work"
}
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null

$script:failures = New-Object System.Collections.ArrayList
function Add-Check([string]$Name, [bool]$Ok, [string]$Evidence) {
  $result = if ($Ok) { 'PASS' } else { 'FAIL' }
  Write-Output ('[{0}] {1}: {2}' -f $result, $Name, $Evidence)
  if (-not $Ok) { [void]$script:failures.Add($Name) }
}

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class OttoStartupDxNative {
  private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")]
  public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maximum);
  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", SetLastError = true)]
  private static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint msg, UIntPtr wParam, IntPtr lParam,
    uint flags, uint timeoutMs, out IntPtr result);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern IntPtr LoadImage(
    IntPtr instance, string name, uint type, int width, int height, uint flags);
  [DllImport("user32.dll")]
  public static extern bool DestroyIcon(IntPtr icon);

  public static IntPtr LoadIconFile(string path, int width, int height) {
    return LoadImage(IntPtr.Zero, path, 1, width, height, 0x0010);
  }

  public static IntPtr FindOttoWindow(uint processId) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
      uint owner;
      GetWindowThreadProcessId(hWnd, out owner);
      if (owner != processId) return true;
      var name = new StringBuilder(64);
      GetClassName(hWnd, name, name.Capacity);
      if (name.ToString() != "NanoUIWindow") return true;
      found = hWnd;
      return false;
    }, IntPtr.Zero);
    return found;
  }

  public static IntPtr GetIcon(IntPtr hWnd, int kind) {
    IntPtr result;
    IntPtr answered = SendMessageTimeout(
      hWnd, 0x007f, new UIntPtr((uint)kind), IntPtr.Zero,
      0x0002, 1000, out result);
    return answered == IntPtr.Zero ? IntPtr.Zero : result;
  }
}
'@

function Test-BitmapEqual($Left, $Right) {
  if ($Left.Width -ne $Right.Width -or $Left.Height -ne $Right.Height) { return $false }
  for ($y = 0; $y -lt $Left.Height; $y++) {
    for ($x = 0; $x -lt $Left.Width; $x++) {
      if ($Left.GetPixel($x, $y).ToArgb() -ne $Right.GetPixel($x, $y).ToArgb()) { return $false }
    }
  }
  return $true
}

function Test-CornersTransparent($Bitmap) {
  $points = @(
    @(0, 0), @(($Bitmap.Width - 1), 0),
    @(0, ($Bitmap.Height - 1)), @(($Bitmap.Width - 1), ($Bitmap.Height - 1))
  )
  foreach ($point in $points) {
    if ($Bitmap.GetPixel($point[0], $point[1]).A -ne 0) { return $false }
  }
  return $true
}

function Get-SmallIconStructure($Bitmap) {
  $blue = 0
  $dark = 0
  for ($y = 0; $y -lt $Bitmap.Height; $y++) {
    for ($x = 0; $x -lt $Bitmap.Width; $x++) {
      $c = $Bitmap.GetPixel($x, $y)
      if ($c.A -lt 64) { continue }
      if ([int]$c.B -ge [int]$c.R + 30 -and [int]$c.B -ge [int]$c.G + 10) { $blue++ }
      $maximum = [Math]::Max($c.R, [Math]::Max($c.G, $c.B))
      $minimum = [Math]::Min($c.R, [Math]::Min($c.G, $c.B))
      if ($maximum -lt 200 -and $maximum - $minimum -lt 35) { $dark++ }
    }
  }
  return [pscustomobject]@{ Blue = $blue; Dark = $dark }
}

# --- PE metadata and an icon extracted from the actual executable ------------
$sourceIcon = Join-Path (Split-Path $root -Parent) 'resources\icon.ico'
if (-not (Test-Path -LiteralPath $sourceIcon)) { throw "missing source icon: $sourceIcon" }
foreach ($path in @($Exe, $Helper)) {
  $name = Split-Path -Leaf $path
  $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
  $expectedVersion = '0.46.0'
  $zon = Get-Content -LiteralPath (Join-Path $root 'app\build.zig.zon') -Raw
  if ($zon -match '\.version\s*=\s*"([^"]+)"') { $expectedVersion = $Matches[1] }
  $metadataOk = $version.FileDescription -eq 'OTTO Sample Manager' -and
    $version.ProductName -eq 'OTTO Sample Manager' -and
    $version.FileVersion -eq $expectedVersion -and
    $version.CompanyName -eq 'CandaceZcc' -and
    $version.LegalCopyright -eq 'MIT License'
  Add-Check "$name version" $metadataOk (
    'description={0}; product={1}; file={2}; company={3}; copyright={4}' -f
    $version.FileDescription, $version.ProductName, $version.FileVersion,
    $version.CompanyName, $version.LegalCopyright)

  $icon = [Drawing.Icon]::ExtractAssociatedIcon($path)
  $bitmap = $icon.ToBitmap()
  $png = Join-Path $OutDir ($name + '.png')
  $bitmap.Save($png, [Drawing.Imaging.ImageFormat]::Png)
  $referenceHandle = [OttoStartupDxNative]::LoadIconFile($sourceIcon, $bitmap.Width, $bitmap.Height)
  if ($referenceHandle -eq [IntPtr]::Zero) { throw "LoadImageW failed for $sourceIcon" }
  $referenceIcon = [Drawing.Icon]::FromHandle($referenceHandle)
  $referenceBitmap = $referenceIcon.ToBitmap()
  $pixelsEqual = Test-BitmapEqual $bitmap $referenceBitmap
  $actualCorners = Test-CornersTransparent $bitmap
  $referenceCorners = Test-CornersTransparent $referenceBitmap
  $iconWidth = $bitmap.Width
  $iconHeight = $bitmap.Height
  $referenceBitmap.Dispose()
  $referenceIcon.Dispose()
  [void][OttoStartupDxNative]::DestroyIcon($referenceHandle)
  $bitmap.Dispose()
  $icon.Dispose()
  Add-Check "$name icon" ((Test-Path -LiteralPath $png) -and (Get-Item -LiteralPath $png).Length -gt 0) $png
  Add-Check "$name PE icon pixels + alpha" ($pixelsEqual -and $actualCorners -and $referenceCorners) (
    'size={0}x{1}; pixels_equal={2}; actual_corners_alpha0={3}; source_corners_alpha0={4}' -f
    $iconWidth, $iconHeight, $pixelsEqual, $actualCorners, $referenceCorners)
}

# --- Source ICO directory, every frame's corners, and 16px structure ---------
$iconBytes = [IO.File]::ReadAllBytes($sourceIcon)
$iconCount = [BitConverter]::ToUInt16($iconBytes, 4)
$declaredSizes = @()
for ($i = 0; $i -lt $iconCount; $i++) {
  $offset = 6 + $i * 16
  $width = if ($iconBytes[$offset] -eq 0) { 256 } else { [int]$iconBytes[$offset] }
  $height = if ($iconBytes[$offset + 1] -eq 0) { 256 } else { [int]$iconBytes[$offset + 1] }
  $declaredSizes += ('{0}x{1}' -f $width, $height)
}
$expectedSizes = '16x16,24x24,32x32,48x48,64x64,128x128,256x256'
Add-Check 'source ICO directory sizes' (($declaredSizes -join ',') -eq $expectedSizes) ($declaredSizes -join ',')
foreach ($size in @(16, 24, 32, 48, 64, 128, 256)) {
  $handle = [OttoStartupDxNative]::LoadIconFile($sourceIcon, $size, $size)
  $frameIcon = if ($handle -eq [IntPtr]::Zero) { $null } else { [Drawing.Icon]::FromHandle($handle) }
  $frame = if ($frameIcon) { $frameIcon.ToBitmap() } else { $null }
  $frameOk = $frame -and $frame.Width -eq $size -and $frame.Height -eq $size
  $cornersOk = $frame -and (Test-CornersTransparent $frame)
  Add-Check "source ICO ${size}px decode + alpha" ($frameOk -and $cornersOk) (
    'decoded={0}; corners_alpha0={1}' -f $frameOk, $cornersOk)
  if ($size -eq 16 -and $frame) {
    $smallPng = Join-Path $OutDir 'icon-16.png'
    $frame.Save($smallPng, [Drawing.Imaging.ImageFormat]::Png)
    $structure = Get-SmallIconStructure $frame
    Add-Check 'source ICO 16px folder/blue-bar structure' (
      $structure.Blue -ge 4 -and $structure.Dark -ge 20) (
      'blue_chroma_pixels={0}; neutral_dark_pixels={1}; image={2}' -f
      $structure.Blue, $structure.Dark, $smallPng)
  }
  if ($frame) { $frame.Dispose() }
  if ($frameIcon) { $frameIcon.Dispose() }
  if ($handle -ne [IntPtr]::Zero) { [void][OttoStartupDxNative]::DestroyIcon($handle) }
}

function New-Case([string]$Name, [bool]$Portable) {
  $dir = Join-Path $work $Name
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $caseExe = Join-Path $dir 'otto-lite.exe'
  Copy-Item -LiteralPath $Exe -Destination $caseExe
  Copy-Item -LiteralPath $Helper -Destination (Join-Path $dir 'otto-thumb-host.exe')
  if ($Portable) {
    [IO.File]::WriteAllText((Join-Path $dir 'otto-portable.flag'), '', [Text.UTF8Encoding]::new($false))
  }
  return $dir
}

function Read-ProcessText($Process, $StdoutTask, $StderrTask) {
  return ([string]$StdoutTask.Result + [string]$StderrTask.Result).Trim()
}

# --- A normal hidden snapshot must not create crash.log ----------------------
$normalDir = New-Case 'normal-portable' $true
$normalLog = Join-Path $normalDir 'data\crash.log'
$snapshot = Join-Path $OutDir 'normal.png'
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = Join-Path $normalDir 'otto-lite.exe'
$psi.Arguments = '--settings-probe --nanoui-snapshot="' + $snapshot + '" --nanoui-wait=3'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
Write-Host ('$ "{0}" {1}' -f $psi.FileName, $psi.Arguments)
$process = [Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
$window = [IntPtr]::Zero
$bigIcon = [IntPtr]::Zero
$smallIcon = [IntPtr]::Zero
for ($i = 0; $i -lt 250 -and -not $process.HasExited; $i++) {
  $process.Refresh()
  $window = [OttoStartupDxNative]::FindOttoWindow([uint32]$process.Id)
  if ($window -ne [IntPtr]::Zero) {
    $bigIcon = [OttoStartupDxNative]::GetIcon($window, 1)
    $smallIcon = [OttoStartupDxNative]::GetIcon($window, 0)
    if ($bigIcon -ne [IntPtr]::Zero -and $smallIcon -ne [IntPtr]::Zero) { break }
  }
  Start-Sleep -Milliseconds 20
}
$visible = $window -ne [IntPtr]::Zero -and [OttoStartupDxNative]::IsWindowVisible($window)
$foreground = $window -ne [IntPtr]::Zero -and [OttoStartupDxNative]::GetForegroundWindow() -eq $window
$hiddenIconsOk = $window -ne [IntPtr]::Zero -and $bigIcon -ne [IntPtr]::Zero -and
  $smallIcon -ne [IntPtr]::Zero -and -not $visible -and -not $foreground
Add-Check 'normal hidden HWND WM_GETICON big/small' $hiddenIconsOk (
  'hwnd=0x{0:X}; big=0x{1:X}; small=0x{2:X}; visible={3}; foreground={4}' -f
  $window.ToInt64(), $bigIcon.ToInt64(), $smallIcon.ToInt64(), $visible, $foreground)
if (-not $process.WaitForExit(15000)) {
  $process.Kill()
  $process.WaitForExit()
  Add-Check 'normal startup' $false 'snapshot process timed out'
} else {
  $text = Read-ProcessText $process $stdout $stderr
  $ok = $process.ExitCode -eq 0 -and (Test-Path -LiteralPath $snapshot) -and
    -not (Test-Path -LiteralPath $normalLog)
  Add-Check 'normal startup: snapshot, no crash.log' $ok ('exit={0}; log={1}; output={2}' -f
    $process.ExitCode, (Test-Path -LiteralPath $normalLog), $text)
}
$process.Dispose()

# --- Optional crash dialog coverage; never run by the icon/default gate -------
if (-not $IncludeCrash) {
  Write-Output '[SKIP] crash MessageBox cases (pass -IncludeCrash to opt in)'
} else {
function Invoke-CrashCase([string]$Name, [string]$CaseExe, [string]$LocalBase, [string]$ExpectedLog) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $CaseExe
  $psi.Arguments = '--crash-test'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.Environment['LOCALAPPDATA'] = $LocalBase
  Write-Host ('$ "{0}" {1}' -f $CaseExe, $psi.Arguments)
  $process = [Diagnostics.Process]::Start($psi)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $dialogSeen = $false
  $title = ''
  try {
    for ($i = 0; $i -lt 250 -and -not $process.HasExited; $i++) {
      $process.Refresh()
      if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
        $dialogSeen = $true
        $title = $process.MainWindowTitle
        [void][OttoStartupDxNative]::PostMessage($process.MainWindowHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
        break
      }
      Start-Sleep -Milliseconds 20
    }
    if (-not $process.WaitForExit(3000)) {
      $process.Kill()
      $process.WaitForExit()
    }
  } finally {
    if (-not $process.HasExited) {
      $process.Kill()
      $process.WaitForExit()
    }
  }
  $text = Read-ProcessText $process $stdout $stderr
  $exitCode = $process.ExitCode
  $process.Dispose()

  $logExists = Test-Path -LiteralPath $ExpectedLog
  $log = if ($logExists) { Get-Content -LiteralPath $ExpectedLog -Raw } else { '' }
  $required = @('timestamp=', 'version=', 'windows=', 'stage=startup',
    'error=CrashTestRequested', 'executable=' + $CaseExe)
  $fieldsOk = $logExists
  foreach ($token in $required) {
    if (-not $log.Contains($token)) { $fieldsOk = $false }
  }
  $ok = $dialogSeen -and $title -eq 'OTTO Sample Manager' -and $exitCode -eq 1 -and
    $text.Contains('startup failed') -and $fieldsOk
  Add-Check "$Name crash dialog + log" $ok ('dialog={0}; title={1}; exit={2}; log={3}; output={4}' -f
    $dialogSeen, $title, $exitCode, $ExpectedLog, $text)
  if ($logExists) { Write-Output ($Name + " log:`n" + $log.Trim()) }
}

$devProject = Join-Path $work 'dev-project'
$devDir = New-Case 'dev-project\zig-out\bin' $false
$devLocal = Join-Path $work 'dev-local'
Invoke-CrashCase 'dev' (Join-Path $devDir 'otto-lite.exe') $devLocal (Join-Path $devProject '.otto-dev\crash.log')

$installedRoot = Join-Path $work 'installed-root'
$installedDir = New-Case 'installed-root\app' $false
$installedLocal = Join-Path $work 'installed-local'
$installedLog = Join-Path $installedRoot 'data\crash.log'
Invoke-CrashCase 'installed' (Join-Path $installedDir 'otto-lite.exe') $installedLocal $installedLog
Add-Check 'installed writes crash.log beside app under root\data' (
  (Test-Path -LiteralPath $installedLog) -and
  -not (Test-Path -LiteralPath (Join-Path $installedDir 'data\crash.log')) -and
  -not (Test-Path -LiteralPath (Join-Path $installedLocal 'OTTO\crash.log'))) $installedLog

$portableDir = New-Case 'portable' $true
$portableLocal = Join-Path $work 'portable-local'
$portableLog = Join-Path $portableDir 'data\crash.log'
Invoke-CrashCase 'portable' (Join-Path $portableDir 'otto-lite.exe') $portableLocal $portableLog
Add-Check 'portable never writes LOCALAPPDATA crash.log' (
  -not (Test-Path -LiteralPath (Join-Path $portableLocal 'OTTO\crash.log'))) $portableLocal
}

if ($script:failures.Count -gt 0) {
  Write-Output ('== startup-dx: FAIL ({0}) ==' -f ($script:failures -join ', '))
  exit 1
}
Write-Output '== startup-dx: PASS =='
exit 0
