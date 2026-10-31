# One command: build OTTO Lite and verify window opacity end to end.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\opacity.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\opacity.ps1 -Release
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\opacity.ps1 -NoBuild
#
# Every run builds a REAL HWND with --settings-probe: 380x700, hidden, never
# activated, no taskbar entry, and --nanoui-snapshot makes it exit. The numbers
# come from the flags Windows itself keeps (WS_EX_LAYERED +
# GetLayeredWindowAttributes), not from anything the app remembered.
#
# What this proves:
#   1. no settings file: opacity=255, NOT layered, getOpacity=null
#      (255 removes WS_EX_LAYERED; see zig/ports/src/win_window.zig)
#   2. settings {"opacity":153}: startup opacity=153, layered, getOpacity=153
#   3. settings {"opacity":255}: startup opacity=255, not layered
#   4. dragging the panel slider is hot: the real window is 60% on that frame,
#      before the panel closes (getOpacity=153)
#   5. closing the panel persists ("opacity":153); the next start reads it back
#   6. --d3d prints exactly one opacity-d3d-warning line (flip model ignores
#      SetLayeredWindowAttributes)
#   7. the foreground window never changes (hidden + WS_EX_NOACTIVATE)
#
# The panel is driven by coordinates (the panel is fixed at 380 points, so its
# geometry is stable; a 2x screenshot of the same layout shows the slider at
# y=196 points). If the panel layout changes, update these four numbers:
#   card x=24..356, padding 16 -> slider track x=40..340, y=196
#   ui.slider: t=(x-40-9)/(300-18); 60% -> 218, 100% -> 336
#   header settings button (top right) -> 352,57; panel close button -> 316,95
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
$panelShot = Join-Path $root 'snapshot-opacity.png'

$sliderY = 196
$x60 = 218
$x100 = 336
$xSettings = 352
$ySettings = 57
$xClose = 316
$yClose = 95

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
using System.Runtime.InteropServices;
public class OpacityFocus {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@

$results = @()
function Check([string]$name, [bool]$ok, [string]$detail) {
  $script:results += [pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail }
  $tag = if ($ok) { 'PASS' } else { 'FAIL' }
  Write-Output ('  [{0}] {1}: {2}' -f $tag, $name, $detail)
}

# Writes the dev settings file the app reads (exe-adjacent, see settings_store).
function Write-Settings([string]$json) {
  [System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding($false)))
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

function Get-WarningLines($lines) {
  return @($lines | Where-Object { $_ -match '^otto-lite: opacity-d3d-warning ' })
}

# Runs one case and checks the exit code plus "the foreground window did not
# change" (nothing here is allowed to pop up or take focus).
function Run-Case([string]$name, [string[]]$Argv) {
  $fgBefore = [OpacityFocus]::GetForegroundWindow()
  $r = Invoke-Probe $Argv
  $fgAfter = [OpacityFocus]::GetForegroundWindow()
  Check ("{0} exit" -f $name) ($r.Code -eq 0) ("exit={0}" -f $r.Code)
  Check ("{0} foreground" -f $name) ($fgBefore -eq $fgAfter) ("before=0x{0:x} after=0x{1:x} changed={2}" -f $fgBefore.ToInt64(), $fgAfter.ToInt64(), ($fgBefore -ne $fgAfter))
  return $r
}

$shots = Join-Path $shotDir 'shot.png'
$baseArgs = @($library, '--settings-probe')

# --- 1. default: no settings file -> 255, not layered -------------------------
Write-Output ''
Write-Output '== 1. default (no settings file): 255 = not layered =='
Remove-Item $settings -ErrorAction SilentlyContinue
$r = Run-Case 'default' ($baseArgs + @("--nanoui-snapshot=$shots"))
$lines = @(Get-OpacityLines $r.Lines)
$line = if ($lines.Count -gt 0) { $lines[-1] } else { '(no opacity line)' }
Check 'default startup' ($line -match 'opacity=255 layered=false getOpacity=null visible=false') $line

# --- 2. a saved 60% applies on startup --------------------------------------
Write-Output ''
Write-Output '== 2. settings opacity=153 (60%): applied on startup =='
Write-Settings '{"always_on_top":false,"update_url":null,"l2_budget_mib":64,"l3_budget_mib":256,"opacity":153}'
$r = Run-Case 'saved-60' ($baseArgs + @("--nanoui-snapshot=$shots"))
$lines = @(Get-OpacityLines $r.Lines)
$line = if ($lines.Count -gt 0) { $lines[-1] } else { '(no opacity line)' }
Check '60% startup' ($line -match 'opacity=153 layered=true getOpacity=153 visible=false') $line

# --- 3. 255 removes WS_EX_LAYERED again -------------------------------------
Write-Output ''
Write-Output '== 3. settings opacity=255 (100%): layered bit removed =='
Write-Settings '{"always_on_top":false,"update_url":null,"l2_budget_mib":64,"l3_budget_mib":256,"opacity":255}'
$r = Run-Case 'saved-100' ($baseArgs + @("--nanoui-snapshot=$shots"))
$lines = @(Get-OpacityLines $r.Lines)
$line = if ($lines.Count -gt 0) { $lines[-1] } else { '(no opacity line)' }
Check '100% startup' ($line -match 'opacity=255 layered=false getOpacity=null visible=false') $line

# --- 4+5. panel slider is hot, closing persists ------------------------------
Write-Output ''
Write-Output '== 4. panel: drag the slider to 60%, then close (persist) =='
$script60 = "at:$xSettings,$ySettings;at:$x60,$sliderY;at:$xClose,$yClose"
$r = Run-Case 'panel-60' ($baseArgs + @("--nanoui-snapshot=$shots", "--nanoui-script=$script60"))
$lines = @(Get-OpacityLines $r.Lines)
# Two lines: startup 255, then the slider frame 153 (before the panel closed).
$hot = if ($lines.Count -gt 0) { $lines[-1] } else { '(no opacity line)' }
Check 'slider is hot' ($hot -match 'opacity=153 layered=true getOpacity=153 visible=false') $hot
Check 'hot apply before close' ($lines.Count -eq 2) ("opacity lines={0} (want 2: startup + slider)" -f $lines.Count)
$allHidden = ($lines.Count -gt 0) -and (@($lines | Where-Object { $_ -notmatch 'visible=false' }).Count -eq 0)
Check 'window stays hidden' $allHidden ("every opacity line has visible=false ({0} lines)" -f $lines.Count)

$saved = if (Test-Path $settings) { [System.IO.File]::ReadAllText($settings) } else { '' }
Check 'close persists 153' ($saved -match '"opacity":153') $saved

# --- 5. restart restores, and the panel snapshot shows the 60% slider --------
Write-Output ''
Write-Output '== 5. restart: 153 restored + panel snapshot at 60% =='
$r = Run-Case 'restart-60' ($baseArgs + @("--nanoui-snapshot=$panelShot", "--nanoui-script=at:$xSettings,$ySettings"))
$lines = @(Get-OpacityLines $r.Lines)
$line = if ($lines.Count -gt 0) { $lines[-1] } else { '(no opacity line)' }
Check 'restart restores 153' ($line -match 'opacity=153 layered=true getOpacity=153 visible=false') $line
Check 'panel snapshot written' (Test-Path $panelShot) $panelShot

# --- 6. --d3d says it may not work (one line, not silent) --------------------
Write-Output ''
Write-Output '== 6. --d3d: one opacity-d3d-warning line =='
$r = Run-Case 'd3d' ($baseArgs + @('--d3d', "--nanoui-snapshot=$shots"))
$warnings = @(Get-WarningLines $r.Lines)
$warn = if ($warnings.Count -gt 0) { $warnings[-1] } else { '(no warning line)' }
Check 'd3d warning printed' ($warnings.Count -eq 1) ("lines={0}" -f $warnings.Count)
Check 'd3d warning says the alpha may not apply' ($warn -match 'alpha=153') $warn
$d3dOpacity = @(Get-OpacityLines $r.Lines)
$line = if ($d3dOpacity.Count -gt 0) { $d3dOpacity[-1] } else { '(no opacity line)' }
Check 'd3d still applies the bit' ($line -match 'opacity=153 layered=true') $line

# --- 7. back to 100% through the panel ---------------------------------------
Write-Output ''
Write-Output '== 7. panel: 60% -> 100%, close, persist =='
$script100 = "at:$xSettings,$ySettings;at:$x100,$sliderY;at:$xClose,$yClose"
$r = Run-Case 'panel-100' ($baseArgs + @("--nanoui-snapshot=$shots", "--nanoui-script=$script100"))
$lines = @(Get-OpacityLines $r.Lines)
$line = if ($lines.Count -gt 0) { $lines[-1] } else { '(no opacity line)' }
Check 'slider back to 100%' ($line -match 'opacity=255 layered=false getOpacity=null visible=false') $line
$saved = if (Test-Path $settings) { [System.IO.File]::ReadAllText($settings) } else { '' }
Check 'close persists 255' ($saved -match '"opacity":255') $saved

# --- summary ---------------------------------------------------------------
$failed = @($results | Where-Object { -not $_.Ok })
Write-Output ''
Write-Output '== summary: window opacity (real hidden HWND, GDI present) =='
$results | ForEach-Object {
  $tag = if ($_.Ok) { 'PASS' } else { 'FAIL' }
  Write-Output ('  [{0}] {1}' -f $tag, $_.Name)
}
Write-Output ('  {0} checks, {1} passed, {2} failed' -f $results.Count, ($results.Count - $failed.Count), $failed.Count)
Write-Output ('  panel snapshot: {0}' -f $panelShot)

if ($failed.Count -gt 0) { exit 1 }
exit 0
