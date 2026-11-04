# 三形态审计：dev / portable / installed。所有数据都在临时目录，旧 APPDATA 只放假毒丸。
[CmdletBinding()]
param(
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe',
  [string]$AppDir = '',
  [string]$Samples = 'C:\src\otto-testkit\samples',
  [string]$TempRoot = '',
  [switch]$SkipBuild,
  [switch]$Release,
  [switch]$KeepTemp,
  [switch]$Hermetic # 兼容旧命令行；单根 installed 本来就不依赖 APPDATA。
)
$ErrorActionPreference = 'Stop'
if (-not $AppDir) { $AppDir = Join-Path $PSScriptRoot 'app' }
$script:app = [IO.Path]::GetFullPath($AppDir)
$script:samples = [IO.Path]::GetFullPath($Samples)
if (-not $TempRoot) { $TempRoot = Join-Path $env:TEMP 'otto-verify-distribution' }
$script:temp = [IO.Path]::GetFullPath($TempRoot)
$script:checks = [Collections.ArrayList]::new()
$script:forms = @{}

function Add-Check([string]$Form, [string]$Name, [bool]$Ok, [string]$Detail = '') {
  [void]$script:checks.Add([pscustomobject]@{ Form = $Form; Name = $Name; Ok = $Ok })
  Write-Output ('  [{0}] {1}: {2}{3}' -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Form, $Name,
    $(if ($Detail) { ' — ' + $Detail } else { '' }))
}
function Get-Sha([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Invoke-Otto([string]$Exe, [string]$Arguments) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $Exe; $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  foreach ($entry in @(
    @('APPDATA', $script:fakeAppData), @('LOCALAPPDATA', $script:fakeLocal),
    @('TEMP', $script:fakeTemp), @('TMP', $script:fakeTemp))) {
    $psi.EnvironmentVariables[$entry[0]] = $entry[1]
  }
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(60000)) { $p.Kill(); throw " Otto probe timeout: $Exe $Arguments" }
  $result = [pscustomobject]@{ Code = $p.ExitCode; Text = ([string]$out.Result + [string]$err.Result) }
  $p.Dispose(); return $result
}
function Copy-Form([string]$Dir, [bool]$Portable) {
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  Copy-Item -LiteralPath $script:exe -Destination (Join-Path $Dir 'otto-lite.exe')
  Copy-Item -LiteralPath $script:helper -Destination (Join-Path $Dir 'otto-thumb-host.exe')
  if ($Portable) {
    [IO.File]::WriteAllText((Join-Path $Dir 'otto-portable.flag'), '', [Text.UTF8Encoding]::new($false))
  }
  return (Join-Path $Dir 'otto-lite.exe')
}
function Assert-Version([string]$Form, [string]$Exe, [string]$Mode) {
  $run = Invoke-Otto $Exe '--version'
  $expected = "otto-lite $($script:version) ($Mode)"
  Add-Check $Form "--version = $expected" ($run.Code -eq 0 -and $run.Text.Trim() -eq $expected) $run.Text.Trim()
}
function Import-Library([string]$Form, [string]$Exe, [string]$Expected) {
  $run = Invoke-Otto $Exe ('--import-into "{0}"' -f $script:samples)
  Add-Check $Form 'import writes the form-owned library.otto' (
    $run.Code -eq 0 -and (Test-Path -LiteralPath $Expected -PathType Leaf) -and
    $run.Text.Contains('wrote=' + $Expected)) "exit=$($run.Code) path=$Expected"
}
function Write-Settings([string]$Form, [string]$Exe, [string]$Expected, [string]$Cache) {
  $shot = Join-Path $script:temp ($Form + '.png')
  $arguments = '--nanoui-snapshot="{0}" --nanoui-script={1}' -f $shot, 'click:设置;at:298,222;click:关闭'
  $run = Invoke-Otto $Exe $arguments
  $settingsOk = $false; $opacity = -1
  if (Test-Path -LiteralPath $Expected -PathType Leaf) {
    try { $opacity = [int](Get-Content -LiteralPath $Expected -Raw | ConvertFrom-Json).opacity } catch { }
    $settingsOk = $opacity -eq 153
  }
  Add-Check $Form 'hidden panel writes settings.json with opacity=153' (
    $run.Code -eq 0 -and $settingsOk -and (Test-Path -LiteralPath $shot -PathType Leaf)) "exit=$($run.Code) opacity=$opacity"
  Add-Check $Form 'thumbnail cache is in the form-owned cache directory' (
    Test-Path -LiteralPath $Cache -PathType Container) $Cache
}
function Complete-Form([string]$Form) {
  $mine = @($script:checks | Where-Object { $_.Form -eq $Form })
  $bad = @($mine | Where-Object { -not $_.Ok })
  $verdict = if ($bad.Count -eq 0 -and $mine.Count -gt 0) { 'PASS' } else { 'FAIL' }
  $script:forms[$Form] = $verdict
  Write-Output ('{0} checks={1}/{2} {3}' -f $Form, ($mine.Count - $bad.Count), $mine.Count, $verdict)
}

try {
  if (-not $SkipBuild) {
    if (-not (Test-Path -LiteralPath $Zig -PathType Leaf)) { throw "zig not found: $Zig" }
    Push-Location $script:app
    try {
      if ($Release) { & $Zig build -Drelease=true } else { & $Zig build }
      if ($LASTEXITCODE -ne 0) { throw "zig build failed: $LASTEXITCODE" }
    } finally { Pop-Location }
  }
  $script:exe = Join-Path $script:app 'zig-out\bin\otto-lite.exe'
  $script:helper = Join-Path $script:app 'zig-out\bin\otto-thumb-host.exe'
  $manifest = Get-Content -LiteralPath (Join-Path $script:app 'build.zig.zon') -Raw
  if ($manifest -notmatch '\.version\s*=\s*"([^"]+)"') { throw 'manifest version missing' }
  $script:version = $Matches[1]
  foreach ($path in @($script:exe, $script:helper, $script:samples)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "missing input: $path" }
  }
  $realTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
  if (-not $script:temp.StartsWith($realTemp + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "TempRoot must stay below the real TEMP: $($script:temp)"
  }
  if (Test-Path -LiteralPath $script:temp) { Remove-Item -LiteralPath $script:temp -Recurse -Force }
  $script:fakeAppData = Join-Path $script:temp 'fake-roaming'
  $script:fakeLocal = Join-Path $script:temp 'fake-local'
  $script:fakeTemp = Join-Path $script:temp 'fake-temp'
  foreach ($dir in @($script:temp, $script:fakeAppData, $script:fakeLocal, $script:fakeTemp)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $legacy = Join-Path $script:fakeAppData 'OTTO'
  New-Item -ItemType Directory -Force -Path $legacy | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $legacy 'library.otto'), [byte[]](0x4f,0x4c,0x44))
  $legacyHash = Get-Sha (Join-Path $legacy 'library.otto')
  $fixture = Join-Path $script:app 'fixtures\library.json'
  $fixtureHash = Get-Sha $fixture
  $binBefore = @(Get-ChildItem -LiteralPath (Join-Path $script:app 'zig-out\bin') -File -Force |
    Sort-Object Name | ForEach-Object { $_.Name + '|' + $_.Length + '|' + (Get-Sha $_.FullName) })

  Write-Output '== dev =='
  $realDevSettings = Join-Path $script:app '.otto-dev\settings.json'
  $realDevSettingsHash = Get-Sha $realDevSettings
  $devProject = Join-Path $script:temp 'dev-project'
  $devExe = Copy-Form (Join-Path $devProject 'zig-out\bin') $false
  Assert-Version 'dev' $devExe 'dev'
  $devData = Join-Path $devProject '.otto-dev'
  Write-Settings 'dev' $devExe (Join-Path $devData 'settings.json') (Join-Path $devData 'cache\thumbs')
  Add-Check 'dev' 'fixture, zig-out, and real dev settings stay untouched' (
    (Get-Sha $fixture) -eq $fixtureHash -and
    (Get-Sha $realDevSettings) -eq $realDevSettingsHash -and
    -not (Test-Path -LiteralPath (Join-Path $script:app 'zig-out\bin\data')))
  Complete-Form 'dev'

  Write-Output '== portable =='
  $portable = Join-Path $script:temp 'portable'
  $portableExe = Copy-Form $portable $true
  Assert-Version 'portable' $portableExe 'portable'
  Import-Library 'portable' $portableExe (Join-Path $portable 'data\library.otto')
  Write-Settings 'portable' $portableExe (Join-Path $portable 'data\settings.json') (Join-Path $portable 'data\cache\thumbs')
  Complete-Form 'portable'

  Write-Output '== installed: <root>/app + data + cache =='
  $root = Join-Path $script:temp 'installed-root'
  $installedExe = Copy-Form (Join-Path $root 'app') $false
  Assert-Version 'installed' $installedExe 'installed'
  Import-Library 'installed' $installedExe (Join-Path $root 'data\library.otto')
  Write-Settings 'installed' $installedExe (Join-Path $root 'data\settings.json') (Join-Path $root 'cache\thumbs')
  Add-Check 'installed' 'cache is a sibling of data; legacy APPDATA is unchanged' (
    -not (Test-Path -LiteralPath (Join-Path $root 'data\cache')) -and
    (Get-Sha (Join-Path $legacy 'library.otto')) -eq $legacyHash)
  Complete-Form 'installed'

  $binAfter = @(Get-ChildItem -LiteralPath (Join-Path $script:app 'zig-out\bin') -File -Force |
    Sort-Object Name | ForEach-Object { $_.Name + '|' + $_.Length + '|' + (Get-Sha $_.FullName) })
  Add-Check 'script' 'zig-out/bin has no runtime writes' (
    (@(Compare-Object $binBefore $binAfter).Count -eq 0)) "files=$($binAfter.Count)"
} catch {
  Add-Check 'script' 'unexpected exception' $false $_.Exception.Message
} finally {
  if ((Test-Path -LiteralPath $script:temp) -and -not $KeepTemp) {
    Remove-Item -LiteralPath $script:temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
$all = @($script:checks); $bad = @($all | Where-Object { -not $_.Ok })
$formBad = @($script:forms.GetEnumerator() | Where-Object { $_.Value -ne 'PASS' })
$ok = $bad.Count -eq 0 -and $script:forms.Count -eq 3 -and $formBad.Count -eq 0
Write-Output ('distribution: {0} checks={1}/{2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }),
  ($all.Count - $bad.Count), $all.Count)
exit $(if ($ok) { 0 } else { 1 })
