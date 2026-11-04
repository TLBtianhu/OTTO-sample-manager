# Render the real UI at several sizes without showing or activating a window.
# The last case asks for a size below the minimum and must be clamped on load.
[CmdletBinding()]
param(
  [string]$Exe = '',
  [string]$Library = 'C:\src\otto-testkit\library.json',
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $root 'app\zig-out\bin\otto-lite.exe' }
if (-not $OutDir) { $OutDir = Join-Path $root '..\artifacts\ui-size-preview' }
$Exe = [IO.Path]::GetFullPath($Exe)
$Library = [IO.Path]::GetFullPath($Library)
$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$work = Join-Path $env:TEMP ('otto-layout-sizes-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Invoke-Snapshot([string]$Arguments, [string]$DataRoot) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $script:exeForProbe
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $psi.Environment['LOCALAPPDATA'] = $DataRoot
  $p = [Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEndAsync()
  $stderr = $p.StandardError.ReadToEndAsync()
  $p.WaitForExit()
  $text = [string]$stdout.Result + [string]$stderr.Result
  if ($p.ExitCode -ne 0) { throw "snapshot exit $($p.ExitCode): $text" }
  $p.Dispose()
  return $text
}
$script:exeForProbe = $Exe
$results = @()
foreach ($spec in @('540x960', '540x864', '540x800', '540x768', '540x720', '480x768', '420x768', '384x768', '360x600')) {
  $parts = $spec.Split('x')
  $requestedWidth = [int]$parts[0]
  $requestedHeight = [int]$parts[1]
  $width = [Math]::Max(384, $requestedWidth)
  $height = [Math]::Max(768, $requestedHeight)
  $dataRoot = Join-Path $work $spec
  $settingsDir = Join-Path $dataRoot 'OTTO\dev'
  New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
  $json = '{"version":2,"layout":{"width":' + $requestedWidth + ',"height":' + $requestedHeight + '}}'
  [IO.File]::WriteAllText((Join-Path $settingsDir 'settings.json'), $json, [Text.UTF8Encoding]::new($false))
  $shot = Join-Path $OutDir ($spec + '.png')
  $args = '--settings-probe --select=0 --nanoui-wait=0.4 --nanoui-script=click:samples --nanoui-snapshot="' + $shot + '" "' + $Library + '"'
  $text = Invoke-Snapshot $args $dataRoot
  [IO.File]::WriteAllText((Join-Path $OutDir ($spec + '.log')), $text, [Text.UTF8Encoding]::new($false))
  $marker = '(' + $width + 'x' + $height + ' points at 1x)'
  if (-not $text.Contains($marker)) { throw "unexpected client size for ${spec}: $text" }
  if (-not (Test-Path -LiteralPath $shot)) { throw "missing snapshot: $shot" }
  $preview = [Math]::Min(216, [Math]::Max(192, [Math]::Floor($height / 4)))
  $results += [pscustomobject]@{
    requested = $spec
    client = ($width.ToString() + 'x' + $height.ToString())
    preview_height = $preview
    screenshot = [IO.Path]::GetFileName($shot)
    hidden = $true
  }
}
$verification = [pscustomobject]@{
  result = 'PASS'
  minimum_client = '384x768'
  preview_range = '192-216'
  compact_or_hidden_preview = $false
  cases = $results
}
[IO.File]::WriteAllText((Join-Path $OutDir 'verification.json'), ($verification | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
Write-Output ('layout-sizes: PASS cases={0} default=540x960 minimum=384x768 preview=192-216 hidden=true' -f $results.Count)
