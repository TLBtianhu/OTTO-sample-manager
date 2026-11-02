# One command: the **hard memory criterion** for the visible scroll form.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\membudget.ps1 -Release
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\membudget.ps1 -Release -NoBuild
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\membudget.ps1 -Release -NoBuild -L2MiB 128
#
# What it asserts (exit 1 on any failure):
#   1. the GDI scroll form's WorkingSet <= 50 MiB   (the charter's resident target);
#   2. the *effective* thumbnail budget l2 + preview <= 48 MiB
#      (the charter's "row thumbnails + 256px preview share" cap).
#
# Both numbers are printed next to their targets, so a green run says what it
# measured. The budget comes from the app's own `otto-lite: cache budget ...`
# line, i.e. what the thumbnail layer actually adopted, not from this script.
#
# Reverse proof (the criterion must be able to fail):
#   -L2MiB 128                 -> clause 2 goes red (128 + 16 > 48);
#   -L2MiB 128 -DistinctFiles -Rows 1200 -Frames 900
#                              -> each row owns a distinct image, the enlarged
#                                 cache really fills, and clause 1 goes red too.
#   (without -L2MiB the default 32 + 16 = 48 is green)
#
# ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.

param(
  [string]$Samples = 'C:\src\otto-testkit\samples',
  [switch]$Release,
  [switch]$NoBuild,
  [int]$Rows = 2000,
  [int]$Frames = 300,
  [int]$L2MiB = 0,
  [switch]$DistinctFiles,
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe'
)

$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
$appDir = Join-Path $root 'app'
$benchRoot = Join-Path $env:TEMP 'otto-membudget'
$filesDir = Join-Path $benchRoot 'files'
$library = Join-Path $benchRoot 'library.json'

if (-not (Test-Path $Zig)) { throw "zig not found: $Zig" }
if (-not (Test-Path $Samples)) { throw "samples dir not found: $Samples" }

$config = if ($Release) { 'release' } elseif ($NoBuild) { 'as-built' } else { 'debug' }
Write-Output ("== membudget: rows={0} frames={1} l2={2} distinct={3} build={4} ==" -f $Rows, $Frames, $(if ($L2MiB -gt 0) { "$L2MiB MiB (override)" } else { 'settings/default' }), [bool]$DistinctFiles, $config)

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

# --- the bench library (same shape as scroll.ps1) ---------------------------
if (Test-Path $benchRoot) { Remove-Item -Recurse -Force $benchRoot -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
$sources = Get-ChildItem $Samples -File |
  Where-Object { $_.Extension -in '.bmp', '.png', '.jpg', '.jpeg', '.gif' } |
  Sort-Object Name
if ($sources.Count -eq 0) { throw "no image files in $Samples" }
$fileCount = if ($DistinctFiles) { $Rows } else { 100 }

for ($i = 0; $i -lt $fileCount; $i++) {
  $src = $sources[$i % $sources.Count]
  $dst = Join-Path $filesDir ('f{0:D4}{1}' -f $i, $src.Extension)
  Copy-Item $src.FullName $dst
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('{"samples":{')
for ($i = 0; $i -lt $Rows; $i++) {
  $fileIndex = $i % $fileCount
  $ext = $sources[$fileIndex % $sources.Count].Extension
  $name = 'f{0:D4}{1}' -f $fileIndex, $ext
  $full = (Join-Path $filesDir $name).Replace('\', '\\')
  if ($i -gt 0) { [void]$sb.Append(',') }
  [void]$sb.Append(('"s_{0}":{{"id":"s_{0}","fileName":"sample {0:D4}","fileExt":"{1}","filePath":"{2}","folderId":"folder_mem","importedAt":{3},"duration":{4}}}' -f $i, $ext, $full, (1000 + $i), ([math]::Round(0.4 + ($i % 50) * 0.1, 2))))
}
[void]$sb.Append('},"groups":{"g_mem":{"id":"g_mem","name":"mem"}}}')
[System.IO.File]::WriteAllText($library, $sb.ToString())
Write-Output ("== bench library: {0} rows, {1} image files under {2} ==" -f $Rows, $fileCount, $filesDir)

$exe = Join-Path $appDir 'zig-out\bin\otto-lite.exe'
$helper = Join-Path $appDir 'zig-out\bin\otto-thumb-host.exe'
if (-not (Test-Path $exe)) { throw "missing exe: $exe" }
if (-not (Test-Path $helper)) { throw "missing helper: $helper (zig build produces both)" }

$argv = @('--bench-scroll', $library, "--frames=$Frames", '--scroll-notches=1')
if ($L2MiB -gt 0) { $argv += "--l2-budget-mib=$L2MiB" }
Write-Output ("== run: otto-lite {0} ==" -f ($argv -join ' '))
$output = @(& $exe @argv 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
  })
$code = $LASTEXITCODE
$output | Where-Object { $_ -match '^scroll-bench: (mem|mem-item|mem-count|summary) ' -or $_ -match '^otto-lite: cache budget' } | ForEach-Object { Write-Output $_ }

$ws = $null
$m = [regex]::Match(($output -join "`n"), 'scroll-bench: mem ws=([0-9.]+)')
if ($m.Success) { $ws = [double]$m.Groups[1].Value }
$budgetMatch = [regex]::Match(($output -join "`n"), 'cache budget l2=(\d+)MiB preview=(\d+)MiB')
$l2 = $null; $preview = $null
if ($budgetMatch.Success) {
  $l2 = [int]$budgetMatch.Groups[1].Value
  $preview = [int]$budgetMatch.Groups[2].Value
}
$bpr = $null
$m = [regex]::Match(($output -join "`n"), 'mem-count .*?bytes_per_row=([0-9.]+)')
if ($m.Success) { $bpr = [double]$m.Groups[1].Value }
# Actual pixels held by the two caches (not the configured budget): the charter
# table says "resident (without L2)", so subtract what is really in the caches.
$l2Used = $null; $previewUsed = $null
$m = [regex]::Match(($output -join "`n"), 'mem-item .*?l2_thumbs=([0-9.]+) preview256=([0-9.]+)')
if ($m.Success) { $l2Used = [double]$m.Groups[1].Value; $previewUsed = [double]$m.Groups[2].Value }

$targetWs = 50.0
$targetCombined = 48
$wsOk = ($null -ne $ws) -and ($ws -le $targetWs)
$budgetKnown = ($null -ne $l2) -and ($null -ne $preview)
$combined = if ($budgetKnown) { $l2 + $preview } else { $null }
$budgetOk = $budgetKnown -and ($combined -le $targetCombined)
$summaryOk = ($output -join "`n") -match 'scroll-bench: summary '

$wsText = if ($null -eq $ws) { 'n/a' } else { '{0:N2}' -f $ws }
$budgetText = if (-not $budgetKnown) { 'n/a' } else { '{0} + {1} = {2}' -f $l2, $preview, $combined }
$rowText = if ($null -eq $bpr) { 'n/a' } else { '{0:N1} B' -f $bpr }
# The charter table's own wording is "resident (without L2)": print that too, so a
# distinct-file library is judged by the same sentence the charter uses.
$wsNoL2 = if (($null -ne $ws) -and ($null -ne $l2Used)) { $ws - $l2Used - $previewUsed } else { $null }
$wsNoL2Text = if ($null -eq $wsNoL2) { 'n/a' } else { '{0:N2}' -f $wsNoL2 }
Write-Output ''
Write-Output '== membudget: assert the charter numbers =='
Write-Output ("  ws       {0,7} MiB  target <= {1:N0} MiB   {2}" -f $wsText, $targetWs, $(if ($wsOk) { 'PASS' } else { 'FAIL' }))
Write-Output ("  ws-no-L2 {0,7} MiB  (charter table: minus l2+preview; diagnostic)" -f $wsNoL2Text)
Write-Output ("  budget   {0,7} MiB  target <= {1} MiB   {2}" -f $budgetText, $targetCombined, $(if ($budgetOk) { 'PASS' } else { 'FAIL' }))
Write-Output ("  rows     {0} rows   row data {1}/row   (charter: 50000 x bytes/row)" -f $Rows, $rowText)
if ($null -ne $bpr) {
  Write-Output ("  projection 50000 rows x {0:N1} B = {1:N2} MiB of row data" -f $bpr, (50000.0 * $bpr / 1048576.0))
}

if (-not $summaryOk) {
  Write-Output ("== membudget: FAIL (no scroll summary; exit {0}) ==" -f $code)
  exit 1
}
if ($wsOk -and $budgetOk) {
  Write-Output ("== membudget: PASS ws={0:N2}/{1:N0} MiB budget={2}/{3} MiB ==" -f $ws, $targetWs, $budgetText, $targetCombined)
  exit 0
}
$why = @()
if (-not $wsOk) { $why += ('ws {0} > {1}' -f $wsText, $targetWs) }
if (-not $budgetOk) { $why += ('l2+preview {0} > {1}' -f $budgetText, $targetCombined) }
Write-Output ("== membudget: FAIL ({0}) ==" -f ($why -join '; '))
exit 1
