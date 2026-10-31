# One command: build OTTO Lite, make a 2000-row library whose rows have real
# images, and run the real-window scroll benchmark twice (default GDI and
# --d3d). See zig\PERF.md section 7 for the Chinese report.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\scroll.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\scroll.ps1 -Release
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\scroll.ps1 -NoBuild -Frames 300
#
# The probe window is a REAL HWND, 380x700, placed OFF SCREEN at (-4000,0),
# created with WS_EX_NOACTIVATE and shown with SW_SHOWNOACTIVATE: it never
# takes the foreground and never appears in the taskbar, but it is visible, so
# WM_PAINT really runs and DWM really has a redirection surface. Add -Edge to
# put it 1 pixel inside the bottom-right corner of the primary display instead
# (DWM definitely composes that one; a single pixel may flash).
#
# Injection: one WM_MOUSEWHEEL every 16.0 ms (62.5 Hz, 4% above 60 Hz so the
# software pacer's +/-0.4 ms wake jitter does not sit on the 16.7 ms line),
# then the message pump
# and UpdateWindow close that frame before the next beat. Frame times come from
# nanoui's frame log (QPC per frame).
#
# ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.

param(
  [string]$Samples = 'C:\src\otto-testkit\samples',
  [switch]$Release,
  [switch]$NoBuild,
  [switch]$Edge,
  [int]$Frames = 300,
  [int]$Rows = 2000,
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe'
)

$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
$appDir = Join-Path $root 'app'
$benchRoot = Join-Path $env:TEMP 'otto-scroll-bench'
$filesDir = Join-Path $benchRoot 'files'
$library = Join-Path $benchRoot 'library.json'

if (-not (Test-Path $Zig)) { throw "zig not found: $Zig" }
if (-not (Test-Path $Samples)) { throw "samples dir not found: $Samples" }

$config = if ($Release) { 'release' } elseif ($NoBuild) { 'as-built' } else { 'debug' }
Write-Output ("== scroll-bench: samples={0} rows={1} frames={2} build={3} edge={4} ==" -f $Samples, $Rows, $Frames, $config, [bool]$Edge)

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

# --- the benchmark's library: N rows over 100 real image files ----------------
if (Test-Path $benchRoot) { Remove-Item -Recurse -Force $benchRoot -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
$sources = Get-ChildItem $Samples -File |
  Where-Object { $_.Extension -in '.bmp', '.png', '.jpg', '.jpeg', '.gif' } |
  Sort-Object Name
if ($sources.Count -eq 0) { throw "no image files in $Samples" }

for ($i = 0; $i -lt 100; $i++) {
  $src = $sources[$i % $sources.Count]
  $dst = Join-Path $filesDir ('f{0:D3}{1}' -f $i, $src.Extension)
  Copy-Item $src.FullName $dst
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('{"samples":{')
for ($i = 0; $i -lt $Rows; $i++) {
  $name = 'f{0:D3}{1}' -f ($i % 100), $sources[($i % 100) % $sources.Count].Extension
  # JSON needs the backslashes escaped; the app wants a Windows path.
  $full = (Join-Path $filesDir $name).Replace('\', '\\')
  if ($i -gt 0) { [void]$sb.Append(',') }
  [void]$sb.Append(('"s_{0}":{{"id":"s_{0}","fileName":"sample {0:D4}","fileExt":"{1}","filePath":"{2}","folderId":"folder_scroll","importedAt":{3},"duration":{4}}}' -f $i, $sources[($i % 100) % $sources.Count].Extension, $full, (1000 + $i), ([math]::Round(0.4 + ($i % 50) * 0.1, 2))))
}
[void]$sb.Append('},"groups":{"g_scroll":{"id":"g_scroll","name":"scroll"}}}')
[System.IO.File]::WriteAllText($library, $sb.ToString())
Write-Output ("== bench library: {0} rows, 100 image files under {1} ==" -f $Rows, $filesDir)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
public class ScrollFocus {
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

$exe = Join-Path $appDir 'zig-out\bin\otto-lite.exe'
if (-not (Test-Path $exe)) { throw "missing exe: $exe" }

$runs = @(
  @{ Name = 'gdi'; Arg = @() },
  @{ Name = 'd3d'; Arg = @('--d3d') }
)

$summary = @()
foreach ($run in $runs) {
  Write-Output ''
  Write-Output ("== run: {0} ==" -f $run.Name)
  $argv = @('--bench-scroll', $library, "--frames=$Frames", '--scroll-notches=1') + $run.Arg
  if ($Edge) { $argv += '--bench-scroll-edge' }
  $fgBefore = [ScrollFocus]::GetForegroundWindow()
  [ScrollFocus]::StartSampling()
  try {
    $output = @(& $exe @argv 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    })
    $code = $LASTEXITCODE
  } finally {
    [ScrollFocus]::StopSampling()
  }
  $fgAfter = [ScrollFocus]::GetForegroundWindow()
  $output | Where-Object { $_ -match '^scroll-bench: ' } | ForEach-Object { Write-Output $_ }
  # Assertion evidence: our window is never the foreground window. before/after
  # are printed as diagnostics only - an unrelated window taking the foreground
  # is legal and must not fail the run.
  $hwndMatch = [regex]::Match(($output -join "`n"), 'window hwnd=0x([0-9a-fA-F]+)')
  $ourHwnd = if ($hwndMatch.Success) { [Convert]::ToInt64($hwndMatch.Groups[1].Value, 16) } else { $null }
  $ourText = if ($null -eq $ourHwnd) { 'unknown' } else { '0x{0:x}' -f $ourHwnd }
  $neverOurs = (($null -ne $ourHwnd) -and ([ScrollFocus]::SampleCount -gt 0) -and
    (-not [ScrollFocus]::SawForeground([long]$ourHwnd)))
  Write-Output ("== exit={0} foreground before=0x{1:x} after=0x{2:x} samples={3} distinct={4} seen=[{5}] our_hwnd={6} never_foreground={7} ==" -f $code, $fgBefore.ToInt64(), $fgAfter.ToInt64(), [ScrollFocus]::SampleCount, [ScrollFocus]::DistinctCount, [ScrollFocus]::SeenText(), $ourText, $neverOurs)
  $line = $output | Where-Object { $_ -match '^scroll-bench: summary ' } | Select-Object -Last 1
  if ($line -match 'summary mode=(\S+) fps=([0-9.]+).*p95=([0-9.]+) max=([0-9.]+) drops=(\d+)/(\d+).*work_p95=([0-9.]+) ws_mib=([0-9.]+) verdict=(\S+)') {
    $summary += [pscustomobject]@{
      Mode = $Matches[1]; Fps = [double]$Matches[2]; P95 = [double]$Matches[3]; Max = [double]$Matches[4]
      Drops = [int]$Matches[5]; Intervals = [int]$Matches[6]; WorkP95 = [double]$Matches[7]
      WsMiB = [double]$Matches[8]; Verdict = $Matches[9]
    }
  } else {
    $summary += [pscustomobject]@{ Mode = $run.Name; Fps = $null; P95 = $null; Max = $null; Drops = $null; Intervals = $null; WorkP95 = $null; WsMiB = $null; Verdict = 'no-summary' }
    Write-Output ("run did not print a summary line (exit {0})" -f $code)
  }
}

Write-Output ''
Write-Output '== summary: real-window scroll, 2000 rows with 100 images (60 Hz target) =='
$summary | ForEach-Object {
  $dropPct = if ($null -eq $_.Intervals -or $_.Intervals -eq 0) { 'n/a' } else { '{0:N1}%' -f (100.0 * $_.Drops / $_.Intervals) }
  Write-Output ("  {0,-4} fps={1,6:N2}  p95={2,5:N2} ms  max={3,6:N2} ms  drops={4}/{5} {6,6}  work_p95={7,5:N2} ms  ws={8,6:N2} MiB  {9}" -f $_.Mode, $_.Fps, $_.P95, $_.Max, $_.Drops, $_.Intervals, $dropPct, $_.WorkP95, $_.WsMiB, $_.Verdict)
}

exit 0
