[CmdletBinding()]
param(
  [string]$Exe = (Join-Path $PSScriptRoot 'app\zig-out\bin\otto-lite.exe'),
  [string]$WorkRoot = (Join-Path $env:TEMP ('otto-remove-accept-' + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-Headless {
  param([string[]]$ChildArgs)
  $arguments = (@($ChildArgs | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' ')
  Write-Host ('  $ "{0}" {1}' -f $Exe, $arguments)
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $Exe
  $psi.Arguments = $arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $process = [System.Diagnostics.Process]::Start($psi)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $text = [string]$stdout.Result + [string]$stderr.Result
  $code = $process.ExitCode
  $process.Dispose()
  if ($code -ne 0) { throw ("exit {0}`n{1}" -f $code, $text) }
  return $text
}

function Assert-Contains([string]$Text, [string]$Token) {
  if (-not $Text.Contains($Token)) { throw ("missing token: {0}`n{1}" -f $Token, $Text) }
}

function Get-SourceManifest([string]$Root) {
  $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $lines = @()
  foreach ($dir in @(Get-ChildItem -LiteralPath $full -Directory -Recurse | Sort-Object FullName)) {
    $relative = $dir.FullName.Substring($full.Length).TrimStart('\')
    $lines += 'D:' + $relative
  }
  foreach ($file in @(Get-ChildItem -LiteralPath $full -File -Recurse | Sort-Object FullName)) {
    $relative = $file.FullName.Substring($full.Length).TrimStart('\')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $lines += ('F:{0}:{1}:{2}' -f $relative, $file.Length, $hash)
  }
  return ($lines -join "`n")
}

function New-Source([string]$Root) {
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $Root 'root\sub\deep')
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $Root 'other')
  [IO.File]::WriteAllBytes((Join-Path $Root 'root\a.wav'), [byte[]](1,2,3,4))
  [IO.File]::WriteAllBytes((Join-Path $Root 'root\sub\b.wav'), [byte[]](5,6,7,8))
  [IO.File]::WriteAllBytes((Join-Path $Root 'root\sub\deep\c.wav'), [byte[]](9,10,11,12))
  [IO.File]::WriteAllBytes((Join-Path $Root 'other\keep.wav'), [byte[]](13,14,15,16))
}

if (-not (Test-Path -LiteralPath $Exe)) { throw "missing exe: $Exe" }
$null = New-Item -ItemType Directory -Force -Path $WorkRoot
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
Write-Host "remove-accept work=$WorkRoot"

# 1) Real hidden HWND: two selected samples, visible header button, restart display.
$multiSource = Join-Path $WorkRoot 'multi-source'
$multiLibrary = Join-Path $WorkRoot 'multi.otto'
New-Source $multiSource
$multiBefore = Get-SourceManifest $multiSource
$import = Invoke-Headless @('--import', $multiSource, '--save', $multiLibrary)
Assert-Contains $import 'added=4'
$multiRun = Invoke-Headless @(
  $multiLibrary, '--watch', $multiSource, '--settings-probe', '--no-prefetch', '--select=0,1',
  '--nanoui-script=click:从库中移除;live:1',
  ('--nanoui-snapshot=' + (Join-Path $WorkRoot 'multi-removed.png'))
)
Assert-Contains $multiRun '已从库中移除 samples=2'
Assert-Contains $multiRun 'remove-window visible=false foreground=false'
$info = Invoke-Headless @('--library-info', $multiLibrary)
Assert-Contains $info 'samples=2'
$restart = Invoke-Headless @(
  $multiLibrary, '--watch', $multiSource, '--settings-probe', '--no-prefetch',
  '--nanoui-wait=1', ('--nanoui-snapshot=' + (Join-Path $WorkRoot 'multi-restart.png'))
)
Assert-Contains $restart 'matched=2/2'
$multiAfter = Get-SourceManifest $multiSource
if ($multiAfter -cne $multiBefore) { throw 'multi source manifest changed' }

# 2) Real hidden HWND: select folder node, Delete recursively removes all four.
$folderSource = Join-Path $WorkRoot 'folder-source'
$folderLibrary = Join-Path $WorkRoot 'folder.otto'
New-Source $folderSource
$folderBefore = Get-SourceManifest $folderSource
$import = Invoke-Headless @('--import', $folderSource, '--save', $folderLibrary)
Assert-Contains $import 'added=4'
$folderRun = Invoke-Headless @(
  $folderLibrary, '--watch', $folderSource, '--settings-probe', '--no-prefetch',
  '--nanoui-script=click:folder-source;key:delete;live:1',
  ('--nanoui-snapshot=' + (Join-Path $WorkRoot 'folder-removed.png'))
)
Assert-Contains $folderRun '已从库中移除 samples=4'
Assert-Contains $folderRun 'remove-window visible=false foreground=false'
$info = Invoke-Headless @('--library-info', $folderLibrary)
Assert-Contains $info 'samples=0'
$restart = Invoke-Headless @(
  $folderLibrary, '--watch', $folderSource, '--settings-probe', '--no-prefetch',
  '--nanoui-wait=1', ('--nanoui-snapshot=' + (Join-Path $WorkRoot 'folder-restart.png'))
)
Assert-Contains $restart 'matched=0/0'
$reimport = Invoke-Headless @('--import', $folderSource, '--library', $folderLibrary, '--save', $folderLibrary)
Assert-Contains $reimport 'added=4'
Assert-Contains $reimport 'restored_exclusions=1'
$restoredInfo = Invoke-Headless @('--library-info', $folderLibrary)
Assert-Contains $restoredInfo 'samples=4'
$folderAfter = Get-SourceManifest $folderSource
if ($folderAfter -cne $folderBefore) { throw 'folder source manifest changed' }

Write-Output 'remove-accept: PASS multi_removed=2 folder_removed=4 restored=4 restart=2/2+0/0 source_manifests=2 unchanged=2 hidden_focus=2/2'
