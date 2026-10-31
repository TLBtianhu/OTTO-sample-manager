# One command: verify startup topmost end to end, with the product (not the test
# harness) handling the Windows foreground lock.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\topmost.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\topmost.ps1 -NoBuild
#
# What this proves:
#   1. the port test creates a REAL hidden window and calls setTopmost directly:
#      the caller never calls AttachThreadInput, and WS_EX_TOPMOST still gets set
#   2. a portable copy (<exe>\otto-portable.flag) with data\settings.json
#      always_on_top=true starts with --settings-probe: the real HWND is hidden,
#      never becomes GetForegroundWindow(), and its WS_EX_TOPMOST bit is read
#      back by THIS script (GetWindowLongPtrW, not by the app's own bookkeeping)
#   3. an invalid HWND returns a named error (a focused port test), not a crash
#   4. the harness never calls AttachThreadInput; the app may do it internally
#      for the duration of one SetWindowPos call, and must detach immediately
#
# ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.

param(
  [switch]$NoBuild,
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe'
)

$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
$appDir = Join-Path $root 'app'
$portsDir = Join-Path $root 'ports'
$exe = Join-Path $appDir 'zig-out\bin\otto-lite.exe'
$helper = Join-Path $appDir 'zig-out\bin\otto-thumb-host.exe'
$portable = Join-Path $env:TEMP 'otto-topmost-portable'
$shot = Join-Path $portable 'shot.png'

if (-not (Test-Path $Zig)) { throw "zig not found: $Zig" }

Write-Output '== topmost probe: build =='
if (-not $NoBuild) {
  Push-Location $appDir
  try {
    & $Zig build
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
if (-not (Test-Path $helper)) { throw "missing thumb helper: $helper" }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class TopmostProbe {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtrW(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLongW(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int max);

  private static readonly object gate = new object();
  private static readonly List<IntPtr> seen = new List<IntPtr>();
  private static volatile bool running;
  private static volatile int sampleCount;
  private static Thread worker;

  public static int SampleCount { get { return sampleCount; } }

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
      for (int i = 0; i < seen.Count; i++) { parts[i] = "0x" + seen[i].ToInt64().ToString("x"); }
      return string.Join(",", parts);
    }
  }

  private static string TitleOf(IntPtr hWnd) {
    StringBuilder text = new StringBuilder(256);
    int n = GetWindowTextW(hWnd, text, text.Capacity);
    return n > 0 ? text.ToString(0, n) : "";
  }

  public static long FindMainWindow(int pid) {
    long titled = 0;
    EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
      uint owner;
      GetWindowThreadProcessId(hWnd, out owner);
      if (owner != (uint)pid) { return true; }
      if (TitleOf(hWnd).StartsWith("OTTO Lite")) {
        titled = hWnd.ToInt64();
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return titled;
  }

  public static long ExStyle(long hwnd) {
    if (IntPtr.Size == 8) { return GetWindowLongPtrW(new IntPtr(hwnd), -20).ToInt64(); }
    return GetWindowLongW(new IntPtr(hwnd), -20);
  }

  public static bool IsVisible(long hwnd) {
    return IsWindowVisible(new IntPtr(hwnd));
  }
}
'@

$results = @()
function Check([string]$name, [bool]$ok, [string]$detail) {
  $script:results += [pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail }
  $tag = if ($ok) { 'PASS' } else { 'FAIL' }
  Write-Output ('  [{0}] {1}: {2}' -f $tag, $name, $detail)
}

function Run-FocusedPortTest([string]$filter, [string]$label) {
  Push-Location $portsDir
  try {
    $lines = @(& $Zig test src/win_window_test.zig -luser32 '--test-filter' $filter 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    })
    $code = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  $ran = @($lines | Where-Object { $_ -match [regex]::Escape($filter) })
  $passed = @($lines | Where-Object { $_ -match '^All \d+ tests passed' })
  Check $label ($code -eq 0 -and $ran.Count -ge 1 -and $passed.Count -ge 1) (
    'exit={0} matched_lines={1} summary={2}' -f $code, $ran.Count, ($passed | Select-Object -Last 1))
}

# --- 1. port test: real hidden window, caller never attaches ------------------
Write-Output ''
Write-Output '== 1. port: setTopmost with no caller AttachThreadInput =='
Run-FocusedPortTest 'topmost-foreground-input' 'port no-attach topmost'

# --- 2. invalid handle is a named error, not a crash -------------------------
Write-Output ''
Write-Output '== 2. port: invalid HWND -> named error, no crash =='
Run-FocusedPortTest 'topmost-invalid' 'port invalid handle'

# --- 3. portable startup with always_on_top=true -----------------------------
Write-Output ''
Write-Output '== 3. portable startup: always_on_top=true, hidden probe, external readback =='
if (Test-Path $portable) { Remove-Item -Recurse -Force $portable }
New-Item -ItemType Directory -Path (Join-Path $portable 'data') -Force | Out-Null
Copy-Item $exe $portable
Copy-Item $helper $portable
New-Item -ItemType File -Path (Join-Path $portable 'otto-portable.flag') | Out-Null
[System.IO.File]::WriteAllText(
  (Join-Path $portable 'data\settings.json'),
  '{"always_on_top":true,"update_url":null,"l2_budget_mib":64,"l3_budget_mib":256,"opacity":255}',
  (New-Object System.Text.UTF8Encoding($false)))

$ours = 0
$everTopmost = $false
$everVisible = $false
$lastEx = 0
$lastVisible = $false
$code = -1
$sampledWhileAlive = 0

[TopmostProbe]::StartSampling()
$logText = ''
try {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $portable 'otto-lite.exe'
  $psi.Arguments = '--settings-probe "--nanoui-snapshot=' + $shot + '" --nanoui-wait=1.5'
  $psi.WorkingDirectory = $portable
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $errTask = $p.StandardError.ReadToEndAsync()
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $deadline = [DateTime]::UtcNow.AddSeconds(8)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($p.HasExited) { break }
    $h = [TopmostProbe]::FindMainWindow($p.Id)
    if ($h -ne 0) { $ours = $h; break }
    Start-Sleep -Milliseconds 20
  }
  while ($ours -ne 0 -and -not $p.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    $ex = [TopmostProbe]::ExStyle($ours)
    $vis = [TopmostProbe]::IsVisible($ours)
    $lastEx = $ex
    $lastVisible = $vis
    $sampledWhileAlive = $sampledWhileAlive + 1
    if (($ex -band 8) -ne 0) { $everTopmost = $true }
    if ($vis) { $everVisible = $true }
    Start-Sleep -Milliseconds 20
  }
  $p.WaitForExit(8000) | Out-Null
  if (-not $p.HasExited) {
    $p.Kill()
    $p.WaitForExit(2000) | Out-Null
  }
  $code = $p.ExitCode
  $logText = $errTask.Result
  $outText = $outTask.Result
} finally {
  [TopmostProbe]::StopSampling()
}

$samples = [TopmostProbe]::SampleCount
$seen = [TopmostProbe]::SeenText()
$ourText = if ($ours -ne 0) { '0x{0:x}' -f $ours } else { 'unknown' }
$neverOurs = (($ours -ne 0) -and ($samples -gt 0) -and (-not [TopmostProbe]::SawForeground([long]$ours)))
$topLines = @($logText -split "`r?`n" | Where-Object { $_ -match '^otto-lite: topmost=' })
$topLine = if ($topLines.Count -gt 0) { $topLines[-1] } else { '(no topmost line)' }
$rejects = @($logText -split "`r?`n" | Where-Object { $_ -match 'topmost-rejected' })

Check 'portable startup exit' ($code -eq 0) ("exit={0}" -f $code)
Check 'real HWND found (external)' ($ours -ne 0) ("our_hwnd={0} sampled_while_alive={1}" -f $ourText, $sampledWhileAlive)
Check 'WS_EX_TOPMOST set (external readback)' $everTopmost (
  'ever_topmost={0} last_exstyle=0x{1:x} WS_EX_TOPMOST=0x8' -f $everTopmost, $lastEx)
Check 'window hidden (external)' ((-not $everVisible) -and (-not $lastVisible)) (
  'ever_visible={0} last_visible={1}' -f $everVisible, $lastVisible)
Check 'foreground never ours' $neverOurs (
  'samples={0} seen=[{1}] our_hwnd={2} never_foreground={3}' -f $samples, $seen, $ourText, $neverOurs)
Check 'app read back WS_EX_TOPMOST=true' (($topLine -match 'topmost=true') -and ($topLine -match 'WS_EX_TOPMOST=true') -and ($topLine -match 'visible=false')) $topLine
Check 'no topmost-rejected at startup' ($rejects.Count -eq 0) ("topmost-rejected lines={0}" -f $rejects.Count)
Check 'portable settings path used' ($logText -match [regex]::Escape((Join-Path $portable 'data\settings.json'))) (
  'data\settings.json under the portable directory')

$failed = @($results | Where-Object { -not $_.Ok })
Write-Output ''
Write-Output '== summary: startup topmost (portable, hidden, product handles the foreground lock) =='
$results | ForEach-Object {
  $tag = if ($_.Ok) { 'PASS' } else { 'FAIL' }
  Write-Output ('  [{0}] {1}' -f $tag, $_.Name)
}
Write-Output ('  {0} checks, {1} passed, {2} failed' -f $results.Count, ($results.Count - $failed.Count), $failed.Count)
Write-Output ('  portable dir: {0}' -f $portable)

if ($failed.Count -gt 0) { exit 1 }
exit 0
