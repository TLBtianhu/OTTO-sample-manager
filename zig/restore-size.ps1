# Click Settings -> Restore default size on a real hidden HWND, then restart.
# ASCII only; CreateNoWindow and nanoui snapshot prevent visible UI/focus theft.
[CmdletBinding()]
param(
  [string]$Exe = '',
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $root 'app\zig-out\bin\otto-lite.exe' }
if (-not $OutDir) { $OutDir = Join-Path $root '..\artifacts\restore-default-size' }
$Exe = [IO.Path]::GetFullPath($Exe)
$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$work = Join-Path $env:TEMP ('otto-restore-size-' + [Guid]::NewGuid().ToString('N'))
$settingsDir = Join-Path $work 'OTTO\dev'
New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
$settings = Join-Path $settingsDir 'settings.json'
[IO.File]::WriteAllText($settings, '{"version":2,"layout":{"width":900,"height":1000}}', [Text.UTF8Encoding]::new($false))

function Invoke-Hidden([string]$Arguments) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $script:exeForProbe
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $psi.Environment['LOCALAPPDATA'] = $script:workForProbe
  Write-Host ('$ "{0}" {1}' -f $psi.FileName, $psi.Arguments)
  $p = [Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEndAsync()
  $stderr = $p.StandardError.ReadToEndAsync()
  $p.WaitForExit()
  $text = [string]$stdout.Result + [string]$stderr.Result
  if ($p.ExitCode -ne 0) { throw "hidden probe exit $($p.ExitCode): $text" }
  $p.Dispose()
  return $text
}
$script:exeForProbe = $Exe
$script:workForProbe = $work
$settingsText = -join [char[]](0x8BBE, 0x7F6E)
$restoreText = (-join [char[]](0x6062, 0x590D, 0x9ED8, 0x8BA4, 0x5927, 0x5C0F, 0xFF08)) + '540' + [char]0x00D7 + '960' + [char]0xFF09
$action = 'click:' + $settingsText + ';click:' + $restoreText
$initial = Join-Path $OutDir 'before-900x1000.png'
$first = Invoke-Hidden ('--settings-probe --nanoui-snapshot="' + $initial + '" --nanoui-script="' + $action + '" --nanoui-wait=1')
$json = [IO.File]::ReadAllText($settings)
if ($json -notmatch '"layout":\{"width":540,"height":960\}') {
  throw "button did not save 540x960: $json; $first"
}
$final = Join-Path $OutDir 'restored-click-final.png'
$second = Invoke-Hidden ('--settings-probe --nanoui-snapshot="' + $final + '" --nanoui-wait=1')
if ($second -notmatch '\(540x960 points at 1x\)') {
  throw "restart is not 540x960: $second"
}
$fresh = Join-Path $OutDir 'fresh-default.png'
$script:workForProbe = Join-Path $work 'fresh'
New-Item -ItemType Directory -Force -Path $script:workForProbe | Out-Null
$third = Invoke-Hidden ('--settings-probe --nanoui-snapshot="' + $fresh + '" --nanoui-wait=1')
if ($third -notmatch '\(540x960 points at 1x\)') {
  throw "fresh default is not 540x960: $third"
}
[IO.File]::WriteAllText((Join-Path $OutDir 'probe.log'), ($first + "`n" + $second + "`n" + $third), [Text.UTF8Encoding]::new($false))
Write-Output 'restore-default-size: PASS fresh=540x960; click 900x1000 -> 540x960; restart=540x960; hidden=true'
