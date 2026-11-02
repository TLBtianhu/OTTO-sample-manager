# Verify PE version/icon resources and the startup fatal-error path.
# The crash-test MessageBox is detected by process id and closed immediately.
# All data lives below TEMP; normal startup uses nanoui's hidden snapshot mode.
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
public static class OttoStartupDxNative {
  [DllImport("user32.dll")]
  public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
'@

# --- PE metadata and an icon extracted from the actual executable ------------
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
  $bitmap.Dispose()
  $icon.Dispose()
  Add-Check "$name icon" ((Test-Path -LiteralPath $png) -and (Get-Item -LiteralPath $png).Length -gt 0) $png
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
$psi.Arguments = '--nanoui-snapshot="' + $snapshot + '" --nanoui-wait=1'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
Write-Host ('$ "{0}" {1}' -f $psi.FileName, $psi.Arguments)
$process = [Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
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

# --- Trigger, identify and immediately close exactly one crash dialog --------
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

$devLocal = Join-Path $work 'dev-local'
Invoke-CrashCase 'dev' $Exe $devLocal (Join-Path $devLocal 'OTTO\dev\crash.log')

$installedDir = New-Case 'installed' $false
$installedLocal = Join-Path $work 'installed-local'
$installedLog = Join-Path $installedLocal 'OTTO\crash.log'
Invoke-CrashCase 'installed' (Join-Path $installedDir 'otto-lite.exe') $installedLocal $installedLog
Add-Check 'installed never writes program data\crash.log' (
  -not (Test-Path -LiteralPath (Join-Path $installedDir 'data\crash.log'))) $installedDir

$portableDir = New-Case 'portable' $true
$portableLocal = Join-Path $work 'portable-local'
$portableLog = Join-Path $portableDir 'data\crash.log'
Invoke-CrashCase 'portable' (Join-Path $portableDir 'otto-lite.exe') $portableLocal $portableLog
Add-Check 'portable never writes LOCALAPPDATA crash.log' (
  -not (Test-Path -LiteralPath (Join-Path $portableLocal 'OTTO\crash.log'))) $portableLocal

if ($script:failures.Count -gt 0) {
  Write-Output ('== startup-dx: FAIL ({0}) ==' -f ($script:failures -join ', '))
  exit 1
}
Write-Output '== startup-dx: PASS =='
exit 0
