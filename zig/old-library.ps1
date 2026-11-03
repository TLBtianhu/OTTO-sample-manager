# Verify old/valid/corrupt OTTOLIB behavior without a visible window or real user data.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI.

[CmdletBinding()]
param(
  [string]$Exe = '',
  [string]$Helper = '',
  [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $root 'app\zig-out\bin\otto-lite.exe' }
if (-not $Helper) { $Helper = Join-Path $root 'app\zig-out\bin\otto-thumb-host.exe' }
if (-not $OutDir) { $OutDir = Join-Path $root 'out\old-library' }
$Exe = [IO.Path]::GetFullPath($Exe)
$Helper = [IO.Path]::GetFullPath($Helper)
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $Exe)) { throw "missing exe: $Exe" }
if (-not (Test-Path -LiteralPath $Helper)) { throw "missing helper: $Helper" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$work = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'otto-old-library-accept'))
$tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
if ([IO.Path]::GetDirectoryName($work).TrimEnd('\') -ne $tempRoot) {
  throw "unsafe test directory: $work"
}
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$installed = Join-Path $work 'installed'
$appData = Join-Path $work 'appdata'
$localData = Join-Path $work 'local'
$dataDir = Join-Path $appData 'OTTO'
New-Item -ItemType Directory -Force -Path $installed, $dataDir, $localData | Out-Null
$caseExe = Join-Path $installed 'otto-lite.exe'
Copy-Item -LiteralPath $Exe -Destination $caseExe
Copy-Item -LiteralPath $Helper -Destination (Join-Path $installed 'otto-thumb-host.exe')

$script:checks = 0
$script:failures = New-Object System.Collections.ArrayList
function Add-Check([string]$Name, [bool]$Ok, [string]$Evidence) {
  $script:checks++
  $result = if ($Ok) { 'PASS' } else { 'FAIL' }
  Write-Output ('[{0}] {1}: {2}' -f $result, $Name, $Evidence)
  if (-not $Ok) { [void]$script:failures.Add($Name) }
}

function Invoke-Native([string]$Arguments, [hashtable]$EnvMap) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $caseExe
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  foreach ($key in $EnvMap.Keys) { $psi.Environment[$key] = $EnvMap[$key] }
  Write-Host ('$ "{0}" {1}' -f $caseExe, $Arguments)
  $process = [Diagnostics.Process]::Start($psi)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $timedOut = -not $process.WaitForExit(15000)
  if ($timedOut) {
    $process.Kill()
    $process.WaitForExit()
  }
  $code = $process.ExitCode
  $text = ([string]$stdout.Result + [string]$stderr.Result).Trim()
  $process.Dispose()
  return [pscustomobject]@{ Code = $code; Text = $text; TimedOut = $timedOut }
}

$envMap = @{ APPDATA = $appData; LOCALAPPDATA = $localData }
$emptyJson = Join-Path $work 'empty.json'
$baseOtto = Join-Path $work 'base.otto'
[IO.File]::WriteAllText($emptyJson, '{}', [Text.UTF8Encoding]::new($false))
$converted = Invoke-Native ('--convert "{0}" "{1}"' -f $emptyJson, $baseOtto) $envMap
if ($converted.Code -ne 0 -or -not (Test-Path -LiteralPath $baseOtto)) {
  throw "could not create v2 fixture: $($converted.Text)"
}
$base = [IO.File]::ReadAllBytes($baseOtto)
$library = Join-Path $dataDir 'library.otto'
$crashLog = Join-Path $localData 'OTTO\crash.log'

# Same valid container, except version=1. The decoder rejects it before payload decoding.
$v1 = [byte[]]$base.Clone()
[Array]::Copy([BitConverter]::GetBytes([uint16]1), 0, $v1, 8, 2)
[IO.File]::WriteAllBytes($library, $v1)
$v1Hash = (Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash
$v1Png = Join-Path $OutDir 'v1.png'
$v1Run = Invoke-Native ('--nanoui-snapshot="{0}" --nanoui-wait=1' -f $v1Png) $envMap
$v1Ok = -not $v1Run.TimedOut -and $v1Run.Code -eq 0 -and
  (Test-Path -LiteralPath $v1Png) -and
  $v1Run.Text.Contains('legacy-library-empty version=1') -and
  -not $v1Run.Text.Contains('startup failed') -and
  -not $v1Run.Text.Contains('Segmentation fault') -and
  -not (Test-Path -LiteralPath $crashLog) -and
  (Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash -eq $v1Hash
Add-Check 'v1 installed starts empty, warns, preserves file, no crash log' $v1Ok (
  'exit={0}; snapshot={1}; output={2}' -f $v1Run.Code, (Test-Path -LiteralPath $v1Png), $v1Run.Text)

# Unmodified v2 keeps the old successful startup behavior and emits no legacy warning.
[IO.File]::WriteAllBytes($library, $base)
$v2Png = Join-Path $OutDir 'v2.png'
$v2Run = Invoke-Native ('--nanoui-snapshot="{0}" --nanoui-wait=1' -f $v2Png) $envMap
$v2Ok = -not $v2Run.TimedOut -and $v2Run.Code -eq 0 -and
  (Test-Path -LiteralPath $v2Png) -and
  -not $v2Run.Text.Contains('legacy-library-empty') -and
  -not $v2Run.Text.Contains('startup failed') -and
  -not (Test-Path -LiteralPath $crashLog)
Add-Check 'valid v2 starts normally without legacy warning' $v2Ok (
  'exit={0}; snapshot={1}; output={2}' -f $v2Run.Code, (Test-Path -LiteralPath $v2Png), $v2Run.Text)

# Flip one payload byte without fixing CRC. CLI inspection must name the failure.
$crc = [byte[]]$base.Clone()
$crc[36] = $crc[36] -bxor 0xFF
$crcPath = Join-Path $work 'crc.otto'
[IO.File]::WriteAllBytes($crcPath, $crc)
$crcRun = Invoke-Native ('--library-info "{0}"' -f $crcPath) $envMap
$crcOk = -not $crcRun.TimedOut -and $crcRun.Code -eq 1 -and
  $crcRun.Text.Contains('error=ChecksumMismatch') -and
  -not $crcRun.Text.Contains('legacy-library-empty') -and
  -not $crcRun.Text.Contains('Segmentation fault')
Add-Check 'CRC corruption stays a named error, never empty fallback' $crcOk (
  'exit={0}; output={1}' -f $crcRun.Code, $crcRun.Text)

Remove-Item -LiteralPath $work -Recurse -Force
if ($script:failures.Count -gt 0) {
  Write-Output ('== old-library: FAIL ({0}) ==' -f ($script:failures -join ', '))
  exit 1
}
Write-Output ('== old-library: PASS {0}/{0} ==' -f $script:checks)
exit 0
