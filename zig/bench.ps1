# One command: build OTTO Lite, run the six-item performance bench, print the
# table plus a PASS/FAIL summary and forward the exit code.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\bench.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\bench.ps1 -Big
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\bench.ps1 -Release
#
# -Library   library to load (default C:\src\otto-testkit\library.json)
# -Big       use the 2000-sample fixture (zig\app\fixtures\library.json)
# -Samples   real files for the thumbnail/audio measurements
# -Release   build with -Drelease=true (package.ps1 uses this mode)
# -NoBuild   skip zig build (use the exe already in zig-out\bin)
#
# Exit codes: 0 = every row PASS or SKIP; 1 = at least one FAIL (or a build /
# bench failure). SKIP means "this machine cannot measure it" (e.g. no audio
# endpoint) and is deliberately not a failure.
#
# ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so Chinese
# text here would be mangled. The Chinese report lives in zig\PERF.md.

param(
  [string]$Library = 'C:\src\otto-testkit\library.json',
  [switch]$Big,
  [string]$Samples = 'C:\src\otto-testkit\samples',
  [switch]$Release,
  [switch]$NoBuild,
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe'
)

# Native tools write diagnostics to stderr; under 'Stop' Windows PowerShell
# turns those into terminating errors. Check $LASTEXITCODE ourselves instead.
$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
$appDir = Join-Path $root 'app'
$bigLibrary = Join-Path $appDir 'fixtures\library.json'

if ($Big -and -not $PSBoundParameters.ContainsKey('Library')) {
  $Library = $bigLibrary
}

if (-not (Test-Path $Zig)) { throw "zig not found: $Zig" }
if (-not (Test-Path $Library)) { throw "library not found: $Library" }
if (-not (Test-Path $Samples)) { throw "samples dir not found: $Samples (override with -Samples)" }

$config = if ($Release) { 'release' } elseif ($NoBuild) { 'as-built' } else { 'debug' }
$sampleCount = ([regex]::Matches((Get-Content $Library -Raw), '"id"\s*:')).Count

Write-Output ("== bench: library={0} ({1} samples) samples-dir={2} build={3} ==" -f $Library, $sampleCount, $Samples, $config)
if ($Big -and $sampleCount -ne 2000) {
  Write-Warning ("-Big expects the 2000-sample fixture, found {0} samples" -f $sampleCount)
}

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

$exe = Join-Path $appDir 'zig-out\bin\otto-lite.exe'
$helper = Join-Path $appDir 'zig-out\bin\otto-thumb-host.exe'
if (-not (Test-Path $exe)) { throw "missing exe: $exe" }
if (-not (Test-Path $helper)) { throw "missing thumb helper: $helper (zig build should produce both)" }

Write-Output '== run: otto-lite --bench =='
$output = @(& $exe --bench $Library --bench-samples $Samples 2>&1 | ForEach-Object {
  if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
})
$code = $LASTEXITCODE
$output | ForEach-Object { Write-Output $_ }

$text = $output -join "`n"
$match = [regex]::Match($text, 'PASS=(\d+)\s+FAIL=(\d+)\s+SKIP=(\d+)')
Write-Output ''
if ($match.Success) {
  Write-Output ("== summary: PASS={0} FAIL={1} SKIP={2} exit={3} ==" -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value, $code)
} else {
  Write-Output ("== summary: PASS=? FAIL=? SKIP=? exit={0} (bench did not print a summary) ==" -f $code)
}

exit $code
