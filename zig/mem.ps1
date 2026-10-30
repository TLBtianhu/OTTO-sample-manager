# One command: build OTTO Lite, run the real-window memory probe twice
# (thumbnail isolation on and off), print both breakdown tables, and a
# before/after summary. See zig\PERF.md for the Chinese report.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\mem.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\mem.ps1 -Release
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\mem.ps1 -NoBuild
#
# The probe window is a REAL HWND at 380x700 that is never shown: no popup,
# no focus, no taskbar entry. It loads the library, builds the first frame
# (font scan + glyph atlas), creates the D3D11 device and swap chain, scrolls
# the list until 8 / 50 / 100 thumbnails are cached and drawn, then idles for
# -Idle seconds while the app's own 150 ms tick keeps running.
#
# The library this script generates has 2000 rows cycling over 100 real image
# files copied from -Samples (so every visible row has a thumbnail to draw).
# The copies live under %TEMP%\otto-mem-probe and are recreated every run.
#
# ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.

param(
  [string]$Samples = 'C:\src\otto-testkit\samples',
  [switch]$Release,
  [switch]$NoBuild,
  [int]$Idle = 10,
  [int]$Rows = 2000,
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe'
)

$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
$appDir = Join-Path $root 'app'
$probeRoot = Join-Path $env:TEMP 'otto-mem-probe'
$filesDir = Join-Path $probeRoot 'files'
$library = Join-Path $probeRoot 'library.json'

if (-not (Test-Path $Zig)) { throw "zig not found: $Zig" }
if (-not (Test-Path $Samples)) { throw "samples dir not found: $Samples" }

$config = if ($Release) { 'release' } elseif ($NoBuild) { 'as-built' } else { 'debug' }
Write-Output ("== mem-probe: samples={0} rows={1} build={2} idle={3}s ==" -f $Samples, $Rows, $config, $Idle)

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

# --- the probe's own library: N rows over 100 real image files ---------------
if (Test-Path $probeRoot) { Remove-Item -Recurse -Force $probeRoot -ErrorAction SilentlyContinue }
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
  [void]$sb.Append(('"s_{0}":{{"id":"s_{0}","fileName":"sample {0:D4}","fileExt":"{1}","filePath":"{2}","folderId":"folder_probe","importedAt":{3},"duration":{4}}}' -f $i, $sources[($i % 100) % $sources.Count].Extension, $full, (1000 + $i), ([math]::Round(0.4 + ($i % 50) * 0.1, 2))))
}
[void]$sb.Append('},"groups":{"g_probe":{"id":"g_probe","name":"probe"}}}')
[System.IO.File]::WriteAllText($library, $sb.ToString())
Write-Output ("== probe library: {0} rows, 100 image files under {1} ==" -f $Rows, $filesDir)

$exe = Join-Path $appDir 'zig-out\bin\otto-lite.exe'
$helper = Join-Path $appDir 'zig-out\bin\otto-thumb-host.exe'
if (-not (Test-Path $exe)) { throw "missing exe: $exe" }
if (-not (Test-Path $helper)) { throw "missing helper: $helper (zig build produces both)" }

$runs = @(
  @{ Name = 'isolation-on';  Arg = @() },
  @{ Name = 'isolation-off'; Arg = @('--no-isolation') }
)

$summary = @()
foreach ($run in $runs) {
  Write-Output ''
  Write-Output ("== run: {0} ==" -f $run.Name)
  $argv = @($library, '--mem-probe', '--nanoui-hidden', "--mem-probe-idle=$Idle") + $run.Arg
  $output = @(& $exe @argv 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
  })
  $code = $LASTEXITCODE
  $output | Where-Object { $_ -match '^mem-probe: ' } | ForEach-Object { Write-Output $_ }
  $final = $output | Where-Object { $_ -match 'mem-probe: final ws_mib=([0-9.]+)' } | Select-Object -Last 1
  if ($final -match 'mem-probe: final ws_mib=([0-9.]+) private_mib=([0-9.]+)') {
    $summary += [pscustomobject]@{ Mode = $run.Name; WsMiB = [double]$Matches[1]; PrivateMiB = [double]$Matches[2] }
  } else {
    $summary += [pscustomobject]@{ Mode = $run.Name; WsMiB = $null; PrivateMiB = $null }
    Write-Output ("probe did not print a final line (exit {0})" -f $code)
  }
}

Write-Output ''
Write-Output '== summary: real-window working set (MiB) vs the 50 MiB charter target =='
$summary | ForEach-Object {
  $ws = if ($null -eq $_.WsMiB) { 'n/a' } else { '{0:N2}' -f $_.WsMiB }
  $priv = if ($null -eq $_.PrivateMiB) { 'n/a' } else { '{0:N2}' -f $_.PrivateMiB }
  Write-Output ("  {0,-14} ws={1,7}  private={2,7}" -f $_.Mode, $ws, $priv)
}

exit 0
