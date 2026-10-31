# One command: build OTTO Lite and verify window opacity end to end.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\opacity.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\opacity.ps1 -Release
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\opacity.ps1 -NoBuild
#
# Every run creates a REAL HWND with --settings-probe: hidden, never activated,
# no taskbar entry. Opacity is driven through the product's programmable entry
# instead of mouse coordinates:
#
#   otto-lite <library> --settings-probe --no-isolation --set-opacity=<0..100>
#
# That entry (zig\app\src\opacity_probe.zig) writes the same Settings field the
# panel slider writes, calls the same Panel.applyOpacity, and persists through
# the same atomic write as closing the panel. The assertions read the numbers
# Windows itself keeps (WS_EX_LAYERED + GetLayeredWindowAttributes), not
# anything the app remembered.
#
# --no-isolation is used only to keep the run single-process: this probe is
# about the window, not the thumbnail helper, and the helper's stderr could be
# interleaved into a machine-readable line on a shared console.
#
# What this proves:
#   1. --set-opacity=60: alpha=153, layered, getOpacity=153, hidden
#   2. the settings file has "opacity":153 (same atomic write as the panel)
#   3. a later start with no --set-opacity reads 153 back and applies it
#   4. --set-opacity=100: alpha=255, layered=false, getOpacity=null
#   5. --set-opacity=0: getOpacity=0 (0 is a legal value)
#   6. --d3d --set-opacity=60 still prints exactly one opacity-d3d-warning
#   7. --set-opacity=150 / abc: named error, exit 1, no window
#   8. every run stays hidden and our HWND is never the foreground window
#      (sampled: GetForegroundWindow() != our hwnd at every sample)
#   9. the settings panel snapshot proves the slider UI is still there. It is
#      opened by clicking the "settings" label (`click:TEXT` in nanoui's
#      script DSL), never by pixel coordinates; the image is looked at by eye
#      and the script makes no coordinate assertions about it.
#
# There are no pixel coordinates in this file. Re-layout the panel (different
# label lengths, moved rows, a resized card) and this script keeps passing.
#
# ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.

param(
  [switch]$Release,
  [switch]$NoBuild,
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe'
)

$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
$appDir = Join-Path $root 'app'
$exe = Join-Path $appDir 'zig-out\bin\otto-lite.exe'
$settings = Join-Path $appDir 'zig-out\bin\.otto-settings.json'
$library = Join-Path $appDir 'fixtures\library.json'
$shotDir = Join-Path $env:TEMP 'otto-opacity-probe'
$startupShot = Join-Path $shotDir 'startup.png'
$panelShot = Join-Path $root 'snapshot-opacity.png'

# The settings button is found by its label through nanoui's `click:TEXT`
# script step, not by coordinates. The label is two CJK code points; building
# it from [char] keeps this file ASCII-only (PowerShell 5.1 would misread a
# literal in a BOM-less script).
$settingsLabel = -join ([char[]](0x8BBE, 0x7F6E))

if (-not (Test-Path $Zig)) { throw "zig not found: $Zig" }

$config = if ($Release) { 'release' } elseif ($NoBuild) { 'as-built' } else { 'debug' }
Write-Output ("== opacity probe: build={0} ==" -f $config)

if (-not $NoBuild) {
  Write-Output ("== build ({0}) ==" -f $config)
  Push-Location $appDir
  try {
    if ($Release) { & $Zig build -Drelease=true } else { & $Zig build }
    $buildCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  if ($buildCode -ne 0) {
    Write-Output ("build failed: zig build exit {0}" -f $buildCode)
    exit $buildCode
  }
}

if (-not (Test-Path $exe)) { throw "missing exe: $exe" }
if (-not (Test-Path $library)) { throw "missing fixture library: $library" }
if (Test-Path $shotDir) { Remove-Item -Recurse -Force $shotDir -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $shotDir -Force | Out-Null

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
public class OpacityFocus {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

  private static readonly object gate = new object();
  private static readonly List<IntPtr> seen = new List<IntPtr>();
  private static volatile bool running;
  private static volatile int sampleCount;
  private static Thread worker;

  public static int SampleCount { get { return sampleCount; } }

  public static int DistinctCount {
    get { lock (gate) { return seen.Count; } }
  }

  public static void StartSampling() {
    lock (gate) { seen.Clear(); }
    sampleCount = 0;
    running = true;
    worker = new Thread(new ThreadStart(delegate {
      while (running) {
        IntPtr fg = GetForegroundWindow();
        sampleCount = sampleCount + 1;
        lock (gate) { if (!seen.Contains(fg)) { seen.Add(fg); } }
        Thread.Sleep(1);
      }
    }));
    worker.IsBackground = true;
    worker.Start();
    // Take at least one sample before the probe starts, so "0 samples" can
    // never be mistaken for a passing check.
    for (int i = 0; i < 100 && sampleCount == 0; i++) { Thread.Sleep(1); }
  }

  public static void StopSampling() {
    running = false;
    if (worker != null) { worker.Join(2000); worker = null; }
  }

  public static bool SawForeground(long hwnd) {
    lock (gate) { return seen.Contains(new IntPtr(hwnd)); }
  }

  public static string SeenText() {
    lock (gate) {
      string[] parts = new string[seen.Count];
      for (int i = 0; i < seen.Count; i++) {
        parts[i] = "0x" + seen[i].ToInt64().ToString("x");
      }
      return string.Join(",", parts);
    }
  }
}
'@

$results = @()
# Every stdout/stderr line from every probe run, for the final "stays hidden"
# assertion. Only the lines that carry a `visible=` field are checked.
$script:allProbeLines = New-Object System.Collections.ArrayList

function Check([string]$name, [bool]$ok, [string]$detail) {
  $script:results += [pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail }
  $tag = if ($ok) { 'PASS' } else { 'FAIL' }
  Write-Output ('  [{0}] {1}: {2}' -f $tag, $name, $detail)
}

# Runs the probe; stdout and stderr are merged into one line list.
function Invoke-Probe($Argv) {
  $all = @(& $exe @Argv 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
  })
  return New-Object psobject -Property @{ Code = $LASTEXITCODE; Lines = [string[]]$all }
}

function Get-OpacityLines($lines) {
  return @($lines | Where-Object { $_ -match '^otto-lite: opacity=' })
}

function Get-SetLines($lines) {
  return @($lines | Where-Object { $_ -match '^otto-lite: opacity-set ' })
}

function Get-WarningLines($lines) {
  return @($lines | Where-Object { $_ -match '^otto-lite: opacity-d3d-warning ' })
}

function Get-SettingsLines($lines) {
  return @($lines | Where-Object { $_ -match '^otto-lite: settings path=' })
}

function Last-Line($lines, [string]$fallback) {
  if ($lines.Count -gt 0) { return $lines[-1] }
  return $fallback
}

# The probe prints the HWND it created on every opacity line; the sampler has
# already recorded every foreground HWND it saw. Returns the last one, or null
# when the probe never printed one (which is itself a failed check).
function Get-OurHwnd($lines) {
  $value = $null
  foreach ($line in $lines) {
    $m = [regex]::Match($line, 'hwnd=0x([0-9a-fA-F]+)')
    if ($m.Success) { $value = [Convert]::ToInt64($m.Groups[1].Value, 16) }
  }
  return $value
}

function Read-SettingsFile() {
  if (Test-Path $settings) { return [System.IO.File]::ReadAllText($settings) }
  return ''
}

# Runs one case. The assertion is "our HWND is never GetForegroundWindow()":
# the sampler thread records the foreground throughout the probe. before/after
# are printed as diagnostics only - an unrelated window taking the foreground
# is legal and must not fail this check.
function Run-Case([string]$name, [string[]]$Argv) {
  $fgBefore = [OpacityFocus]::GetForegroundWindow()
  [OpacityFocus]::StartSampling()
  try {
    $r = Invoke-Probe $Argv
  } finally {
    [OpacityFocus]::StopSampling()
  }
  $fgAfter = [OpacityFocus]::GetForegroundWindow()
  $samples = [OpacityFocus]::SampleCount
  $distinct = [OpacityFocus]::DistinctCount
  $seenText = [OpacityFocus]::SeenText()
  $ourHwnd = Get-OurHwnd $r.Lines
  $neverOurs = (($null -ne $ourHwnd) -and ($samples -gt 0) -and
    (-not [OpacityFocus]::SawForeground([long]$ourHwnd)))
  $ourText = if ($null -eq $ourHwnd) { 'unknown' } else { '0x{0:x}' -f $ourHwnd }
  Check ("{0} exit" -f $name) ($r.Code -eq 0) ("exit={0}" -f $r.Code)
  Check ("{0} foreground" -f $name) $neverOurs (
    'samples={0} distinct={1} seen=[{2}] our_hwnd={3} never_foreground={4}; diag before=0x{5:x} after=0x{6:x}' -f
      $samples, $distinct, $seenText, $ourText, $neverOurs, $fgBefore.ToInt64(), $fgAfter.ToInt64())
  foreach ($line in $r.Lines) { $null = $script:allProbeLines.Add($line) }
  return $r
}

$baseArgs = @($library, '--settings-probe', '--no-isolation')

# --- 1. --set-opacity=60: the product entry applies 60% ----------------------
Write-Output ''
Write-Output '== 1. --set-opacity=60: alpha 153, layered, hidden =='
Remove-Item $settings -ErrorAction SilentlyContinue
$r = Run-Case 'set-60' ($baseArgs + @('--set-opacity=60'))
$sets = @(Get-SetLines $r.Lines)
$line = Last-Line $sets '(no opacity-set line)'
Check 'set 60 applied' ($line -match 'percent=60 alpha=153 layered=true getOpacity=153 visible=false') $line
Check 'set 60 printed once' ($sets.Count -eq 1) ("opacity-set lines={0}" -f $sets.Count)

# --- 2. the same atomic write as closing the panel ---------------------------
$saved = Read-SettingsFile
Check 'settings file has opacity 153' ($saved -match '"opacity":153') $saved

# --- 3. restart with no --set-opacity: the saved value is read and applied ---
Write-Output ''
Write-Output '== 2. restart: 153 is read from disk and applied =='
$r = Run-Case 'restart' ($baseArgs + @("--nanoui-snapshot=$startupShot"))
$settingsLines = @(Get-SettingsLines $r.Lines)
$settingsLine = Last-Line $settingsLines '(no settings line)'
Check 'restart read 153 from disk' ($settingsLine -match 'opacity=153') $settingsLine
$opacityLines = @(Get-OpacityLines $r.Lines)
$line = Last-Line $opacityLines '(no opacity line)'
Check 'restart applied 153 on startup' ($line -match 'opacity=153 layered=true getOpacity=153 visible=false') $line
Check 'restart is read-only' (@(Get-SetLines $r.Lines).Count -eq 0) (
  'opacity-set lines={0}' -f @(Get-SetLines $r.Lines).Count)

# --- 4. --set-opacity=100: 255 removes WS_EX_LAYERED -------------------------
Write-Output ''
Write-Output '== 3. --set-opacity=100: layered bit removed =='
$r = Run-Case 'set-100' ($baseArgs + @('--set-opacity=100'))
$sets = @(Get-SetLines $r.Lines)
$line = Last-Line $sets '(no opacity-set line)'
Check 'set 100 cleared the layered bit' ($line -match 'percent=100 alpha=255 layered=false getOpacity=null visible=false') $line
$saved = Read-SettingsFile
Check 'settings file has opacity 255' ($saved -match '"opacity":255') $saved

# --- 5. --set-opacity=0: zero is a legal value, not "unset" ------------------
Write-Output ''
Write-Output '== 4. --set-opacity=0: getOpacity=0, not null =='
$r = Run-Case 'set-0' ($baseArgs + @('--set-opacity=0'))
$sets = @(Get-SetLines $r.Lines)
$line = Last-Line $sets '(no opacity-set line)'
Check 'set 0 is legal' ($line -match 'percent=0 alpha=0 layered=true getOpacity=0 visible=false') $line
$saved = Read-SettingsFile
Check 'settings file has opacity 0' ($saved -match '"opacity":0') $saved

# --- 6. --d3d: the limitation is still announced, once ----------------------
Write-Output ''
Write-Output '== 5. --d3d --set-opacity=60: one opacity-d3d-warning =='
# Start from no settings file (startup alpha 255), so the warning belongs to
# the probe's 60% apply instead of a stale saved value.
Remove-Item $settings -ErrorAction SilentlyContinue
$r = Run-Case 'd3d' ($baseArgs + @('--d3d', '--set-opacity=60'))
$warnings = @(Get-WarningLines $r.Lines)
$warn = Last-Line $warnings '(no warning line)'
Check 'd3d warning printed once' ($warnings.Count -eq 1) ("lines={0}" -f $warnings.Count)
Check 'd3d warning names alpha 153' ($warn -match 'alpha=153') $warn
$sets = @(Get-SetLines $r.Lines)
$line = Last-Line $sets '(no opacity-set line)'
Check 'd3d still applies the layered bit' ($line -match 'percent=60 alpha=153 layered=true') $line

# --- 7. invalid values: named error, exit 1, no window at all ----------------
Write-Output ''
Write-Output '== 6. invalid values: named error + exit 1 =='
$bad = Invoke-Probe @('--settings-probe', '--set-opacity=150')
$named = @($bad.Lines | Where-Object { $_ -match 'set-opacity-invalid' })
$applied = @($bad.Lines | Where-Object { $_ -match 'opacity-set|hwnd=' })
Check '150 rejected with a named error' (($bad.Code -eq 1) -and ($named.Count -eq 1) -and ($applied.Count -eq 0)) (
  'exit={0} named={1} applied={2} line={3}' -f $bad.Code, $named.Count, $applied.Count, (Last-Line $named '(none)'))

$bad = Invoke-Probe @('--settings-probe', '--set-opacity=abc')
$named = @($bad.Lines | Where-Object { $_ -match 'set-opacity-invalid' })
$applied = @($bad.Lines | Where-Object { $_ -match 'opacity-set|hwnd=' })
Check 'abc rejected with a named error' (($bad.Code -eq 1) -and ($named.Count -eq 1) -and ($applied.Count -eq 0)) (
  'exit={0} named={1} applied={2} line={3}' -f $bad.Code, $named.Count, $applied.Count, (Last-Line $named '(none)'))

# --- 8. panel snapshot: slider UI still there, opened by label ---------------
Write-Output ''
Write-Output '== 7. settings panel snapshot (image only, no coordinate assertions) =='
if (Test-Path $panelShot) { Remove-Item $panelShot -ErrorAction SilentlyContinue }
$r = Run-Case 'panel' ($baseArgs + @(
  "--nanoui-snapshot=$panelShot",
  "--nanoui-script=click:$settingsLabel"
))
$shotOk = $false
$shotDetail = 'missing'
if (Test-Path $panelShot) {
  $bytes = [System.IO.File]::ReadAllBytes($panelShot)
  $isPng = ($bytes.Length -gt 8 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and
    $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47)
  $shotOk = ($isPng -and $bytes.Length -gt 10000)
  $shotDetail = ('{0} bytes png={1}; opened with click:TEXT' -f $bytes.Length, $isPng)
}
Check 'panel snapshot written' $shotOk $shotDetail

# --- 9. the whole run never showed our window --------------------------------
Write-Output ''
Write-Output '== 8. every opacity line stayed hidden =='
$visibleFields = @($script:allProbeLines | Where-Object { $_ -match '^otto-lite: (opacity=|opacity-set )' })
$visibleOnes = @($visibleFields | Where-Object { $_ -notmatch 'visible=false' })
Check 'every opacity line says visible=false' (($visibleFields.Count -gt 0) -and ($visibleOnes.Count -eq 0)) (
  '{0} opacity lines, {1} visible' -f $visibleFields.Count, $visibleOnes.Count)

# --- summary ---------------------------------------------------------------
$failed = @($results | Where-Object { -not $_.Ok })
Write-Output ''
Write-Output '== summary: window opacity (real hidden HWND, product entry --set-opacity) =='
$results | ForEach-Object {
  $tag = if ($_.Ok) { 'PASS' } else { 'FAIL' }
  Write-Output ('  [{0}] {1}' -f $tag, $_.Name)
}
Write-Output ''
Write-Output '== foreground diagnostics (sampled; before/after are not assertions) =='
$results | Where-Object { $_.Name -like '* foreground' } | ForEach-Object {
  Write-Output ('  {0}: {1}' -f $_.Name, $_.Detail)
}
Write-Output ('  {0} checks, {1} passed, {2} failed' -f $results.Count, ($results.Count - $failed.Count), $failed.Count)
Write-Output ('  panel snapshot: {0}' -f $panelShot)

if ($failed.Count -gt 0) { exit 1 }
exit 0
