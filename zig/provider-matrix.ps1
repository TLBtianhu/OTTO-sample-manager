# One row per sample: which preview provider answers, in two rounds (default and
# `--no-shell-preview`), plus the exit code. This is the gate for the
# "every format is self-sufficient" registry (zig/app/src/providers/root.zig).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\provider-matrix.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\provider-matrix.ps1 -Build
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\provider-matrix.ps1 -Exe C:\...\otto-lite.exe
#
# What it asserts, for every row:
#
#   1. the process exits 0 (demo_preview.zig: any Outcome is success, `none` is
#      an honest answer, only "cannot even construct an answer" returns 1);
#   2. `preview: provider=<name>` names the provider the table expects. That is
#      the architecture claim: `img00.png` -> image-wic (our own WIC decode, not
#      the Shell thumbnail), `viper.mp3` -> native-audio (zig-audio's pure Zig
#      MP3 decoder since vendored v0.7 -- it used to be mf-audio), `tone_440.wav`
#      -> wasapi-pcm, `tone_660.flac` -> native-audio (the same vendored
#      decoder), `rabbit320.mp4` -> mf-video;
#   3. the second round really ran with the trimmed registry: it must print
#      `preview: shell-preview=disabled`. Without this assertion a typo in the
#      flag would silently run the default table twice and the row would still be
#      green -- the no-shell column would prove nothing;
#   4. `preview: OK` is present (the run reached the end, not just a provider
#      line);
#   5. `mystery.xyz` is the negative control: both rounds must answer
#      provider=none / outcome=none reason=unsupported. "No preview" must stay
#      visible instead of being swallowed by a fallback.
#
# Expected table (0.16.0 + legacy):
#
#   素材               默认          no-shell
#   img00.png          image-wic     image-wic      (core row: PNG never needs Shell)
#   img00.bmp          image-wic     image-wic
#   viper.mp3          native-audio  native-audio   (vendored zig-audio MP3, pure Zig)
#   rabbit320.mp4      mf-video      mf-video
#   tone_440.wav       wasapi-pcm    wasapi-pcm
#   tone_660.flac      native-audio  native-audio   (vendored zig-audio, pure Zig)
#   legacy-adpcm.wav   wasapi-pcm    wasapi-pcm     (MS ADPCM WAV, zig-audio v0.8)
#   legacy.aiff        native-audio  native-audio   (AIFF PCM16, zig-audio v0.8)
#   mystery.xyz        none          none
#
# The audio rows need an audio endpoint: `wasapi-pcm` (WAV/ADPCM) and
# `native-audio` (FLAC / MP3 / AIFF) initialise the shared-mode device inside
# `open`, and a box with no endpoint makes them decline (then shell-thumbnail may
# answer, or nothing). bench.ps1 calls that SKIP; here it is a FAIL by design -- the
# point of the gate is that audio preview works on this machine, not that it would
# work on one where it cannot.
#
# open_ms is printed for every round but has **no threshold**: a cold decoder or a
# busy audio endpoint legitimately varies by hundreds of ms (viper.mp3 through
# native-audio: 104-108 ms on this box in a release build; the first Media
# Foundation run when it still owned MP3 was 838 ms). The number is there so a
# regression shows up as a visible jump in the table instead of hiding behind a
# boolean.
#
# Why this exists next to the app tests: those tests prove each provider works
# in isolation with fixtures; this script proves the *registry* still answers with
# the right provider for a real file on disk, in a real process, with the Shell
# fallback removed. A provider that starts declining, a Shell thumbnail that
# starts winning back a format, or an order change that lets the fallback answer
# first is invisible to a unit test and obvious here.
#
# Exit codes: 0 = all rows pass; 1 = a row failed, or the exe / a sample / the
# build is missing. A missing sample is a FAIL, not a SKIP: the matrix would
# otherwise report a green table that proved nothing about that format.
#
# No window is shown, no focus is taken, no network is used: `--preview` is the
# headless path in demo_preview.zig (it opens the registry and prints; it never
# creates a window).
#
# This file is UTF-8 **with BOM** on purpose: Windows PowerShell 5.1 reads a
# BOM-less .ps1 as ANSI and would garble the Chinese table.

[CmdletBinding()]
param(
  [string]$Exe = '',
  [string]$Samples = 'C:\src\otto-testkit\samples',
  # Optional: run `zig build` first. health.ps1 has already built, so it does not
  # pass this; a standalone run on a fresh tree can.
  [switch]$Build,
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe'
)

# Native tools write diagnostics to stderr; under 'Stop' Windows PowerShell turns
# those into terminating errors. Every exit code is checked by hand.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:root = $PSScriptRoot
$script:appDir = Join-Path $script:root 'app'
if ([string]::IsNullOrEmpty($Exe)) {
  $Exe = Join-Path $script:appDir 'zig-out\bin\otto-lite.exe'
}

# The expectation table. `Default` / `NoShell` are both spelled out even where
# they are equal: a Shell-only format added later gets
# Default='shell-thumbnail' / NoShell='none', and that difference must be a
# one-line edit here, not a special case in the loop.
$script:cases = @(
  [pscustomobject]@{ Name = 'img00.png';     Default = 'image-wic';  NoShell = 'image-wic';  Reason = '' },
  [pscustomobject]@{ Name = 'img00.bmp';     Default = 'image-wic';  NoShell = 'image-wic';  Reason = '' },
  [pscustomobject]@{ Name = 'viper.mp3';     Default = 'native-audio'; NoShell = 'native-audio'; Reason = '' },
  [pscustomobject]@{ Name = 'rabbit320.mp4'; Default = 'mf-video';   NoShell = 'mf-video';   Reason = '' },
  [pscustomobject]@{ Name = 'tone_440.wav';  Default = 'wasapi-pcm'; NoShell = 'wasapi-pcm'; Reason = '' },
  [pscustomobject]@{ Name = 'tone_660.flac'; Default = 'native-audio'; NoShell = 'native-audio'; Reason = '' },
  # Legacy formats decoded by zig-audio v0.8: MS ADPCM WAV stays with the WAV
  # provider; AIFF is claimed by native-audio.
  [pscustomobject]@{ Name = 'legacy-adpcm.wav'; Default = 'wasapi-pcm'; NoShell = 'wasapi-pcm'; Reason = '' },
  [pscustomobject]@{ Name = 'legacy.aiff';   Default = 'native-audio'; NoShell = 'native-audio'; Reason = '' },
  [pscustomobject]@{ Name = 'mystery.xyz';   Default = 'none';       NoShell = 'none';       Reason = 'unsupported' }
)

# ---------------------------------------------------------------------------
# Output helpers (same display-width rules as health.ps1 / verify-distribution.ps1)
# ---------------------------------------------------------------------------

function Get-DisplayWidth([string]$Text) {
  $width = 0
  foreach ($ch in $Text.ToCharArray()) {
    $code = [int]$ch
    if (($code -ge 0x1100 -and $code -le 0x115F) -or
        ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
        ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
        ($code -ge 0xF900 -and $code -le 0xFAFF) -or
        ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
        ($code -ge 0xFF00 -and $code -le 0xFF60) -or
        ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
      $width += 2
    } else {
      $width += 1
    }
  }
  return $width
}

function Format-Row {
  param(
    [string[]]$Cells,
    [int[]]$Widths
  )
  $parts = @()
  for ($i = 0; $i -lt $Cells.Count; $i++) {
    $pad = $Widths[$i] - (Get-DisplayWidth $Cells[$i])
    if ($pad -lt 0) { $pad = 0 }
    $parts += ($Cells[$i] + (' ' * $pad))
  }
  return (($parts -join '  ').TrimEnd())
}

# Locale-independent number text: the summary line is parsed by health.ps1, so a
# machine whose decimal separator is not '.' must not change the output format.
# Note: [string]::Format takes a *composite* format ("{0:0.00}"), not a custom
# numeric one -- passing '0.00' there prints the literal. ToString does the
# custom numeric format directly.
function Format-Number([double]$Value, [string]$Format) {
  return $Value.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

# ---------------------------------------------------------------------------
# One round: run `--preview <path> [--no-shell-preview]` and parse the lines
# ---------------------------------------------------------------------------

# demo_preview.zig prints one fact per line and one `preview: <key>=<value>`
# line per field. `$Matches[1]` is returned as a string, '' when absent.
function Get-PreviewField([string[]]$Lines, [string]$Pattern) {
  foreach ($line in $Lines) {
    if ($line -match $Pattern) { return [string]$Matches[1] }
  }
  return ''
}

function Test-PreviewLine([string[]]$Lines, [string]$Exact) {
  foreach ($line in $Lines) {
    if ($line.Trim() -eq $Exact) { return $true }
  }
  return $false
}

function Invoke-PreviewRound {
  param(
    [string]$ExePath,
    [string]$Path,
    [bool]$NoShell
  )
  $argv = @('--preview', $Path)
  if ($NoShell) { $argv += '--no-shell-preview' }

  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $lines = @()
  $code = -1
  try {
    $lines = @(& $ExePath @argv 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    })
    $code = $LASTEXITCODE
  } catch {
    $lines = @($_.Exception.Message)
    $code = -1
  }
  $watch.Stop()

  $provider = Get-PreviewField $lines '^preview: provider=(\S+) kind='
  # `provider=<none>` is the no-answer spelling; the table says `none`.
  $provider = $provider.Trim('<', '>')

  $openMsRaw = Get-PreviewField $lines '^preview: open_ms=([0-9.]+)'
  $openMs = $null
  if ($openMsRaw -ne '') {
    $openMs = [double]::Parse($openMsRaw, [System.Globalization.CultureInfo]::InvariantCulture)
  }

  return New-Object psobject -Property @{
    Label         = $(if ($NoShell) { 'no-shell' } else { '默认' })
    NoShell       = $NoShell
    Code          = $code
    Seconds       = [math]::Round($watch.Elapsed.TotalSeconds, 2)
    Lines         = [string[]]$lines
    Provider      = $provider
    Kind          = (Get-PreviewField $lines '^preview: provider=\S+ kind=(\w+)')
    OpenMs        = $openMs
    Outcome       = (Get-PreviewField $lines '^preview: outcome=(\w+)')
    Reason        = (Get-PreviewField $lines '^preview: outcome=none reason=(\w+)')
    HasOk         = (Test-PreviewLine $lines 'preview: OK')
    ShellDisabled = (Test-PreviewLine $lines 'preview: shell-preview=disabled')
  }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Output 'provider 矩阵：默认 / --no-shell-preview 两轮'
Write-Output ('exe:     {0}' -f $Exe)
Write-Output ('samples: {0}' -f $Samples)

if ($Build) {
  if (-not (Test-Path -LiteralPath $Zig)) {
    Write-Output ('致命错误：找不到 zig：{0}' -f $Zig)
    exit 1
  }
  Write-Output ('== build: {0} ==' -f $script:appDir)
  Push-Location $script:appDir
  try {
    $buildOutput = @(& $Zig build 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    })
    $buildCode = $LASTEXITCODE
  } catch {
    $buildOutput = @($_.Exception.Message)
    $buildCode = -1
  } finally {
    Pop-Location
  }
  if ($buildCode -ne 0) {
    $buildOutput | Select-Object -Last 25 | ForEach-Object { Write-Output ('  | ' + $_) }
    Write-Output ('build 失败：zig build exit {0}' -f $buildCode)
    exit 1
  }
  Write-Output '  build: OK'
}

if (-not (Test-Path -LiteralPath $Exe)) {
  Write-Output ('致命错误：找不到 exe：{0}' -f $Exe)
  Write-Output '先 zig build（或加 -Build 参数）；health.ps1 会在 release 构建之后调用本脚本。'
  exit 1
}

if (-not (Test-Path -LiteralPath $Samples -PathType Container)) {
  Write-Output ('致命错误：找不到素材目录：{0}' -f $Samples)
  Write-Output '用 -Samples 指到 otto-testkit\samples。'
  exit 1
}

$rows = New-Object System.Collections.ArrayList
$failureBlocks = New-Object System.Collections.ArrayList
$runCount = 0
$maxOpenMs = 0.0

foreach ($case in $script:cases) {
  $path = Join-Path $Samples $case.Name
  $row = New-Object psobject -Property @{
    Name            = $case.Name
    DefaultProvider = ''
    DefaultMs       = $null
    NoShellProvider = ''
    NoShellMs       = $null
    Ok              = $true
    Problems        = @()
  }

  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    # A missing sample must fail the row: a green table over a renamed file would
    # prove nothing about that format (this is the deliberate-break case).
    $row.Ok = $false
    $row.Problems += ('素材缺失：{0}' -f $path)
    $row.DefaultProvider = '(missing)'
    $row.NoShellProvider = '(missing)'
    $null = $rows.Add($row)
    continue
  }

  $rounds = @(
    [pscustomobject]@{ Expected = $case.Default; NoShell = $false; ProviderKey = 'DefaultProvider'; MsKey = 'DefaultMs' },
    [pscustomobject]@{ Expected = $case.NoShell; NoShell = $true;  ProviderKey = 'NoShellProvider'; MsKey = 'NoShellMs' }
  )

  foreach ($round in $rounds) {
    $r = Invoke-PreviewRound -ExePath $Exe -Path $path -NoShell $round.NoShell
    $runCount++
    $row.($round.ProviderKey) = $(if ($r.Provider -eq '') { '(no provider 行)' } else { $r.Provider })
    $row.($round.MsKey) = $r.OpenMs
    if ($null -ne $r.OpenMs -and $r.OpenMs -gt $maxOpenMs) { $maxOpenMs = $r.OpenMs }

    $bad = @()
    if ($r.Code -ne 0) { $bad += ('exit={0}（期望 0）' -f $r.Code) }
    if (-not $r.HasOk) { $bad += '没有 preview: OK 行' }
    if ($r.Provider -ne $round.Expected) {
      $bad += ('provider={0}（期望 {1}）' -f $(if ($r.Provider -eq '') { '<无>' } else { $r.Provider }), $round.Expected)
    }
    if ($round.NoShell -and -not $r.ShellDisabled) {
      $bad += '没有 shell-preview=disabled 行（--no-shell-preview 没生效？）'
    }
    if ($case.Reason -ne '' -and $r.Reason -ne $case.Reason) {
      $bad += ('reason={0}（期望 {1}）' -f $(if ($r.Reason -eq '') { '<无>' } else { $r.Reason }), $case.Reason)
    }

    if ($bad.Count -gt 0) {
      $row.Ok = $false
      $row.Problems += ('{0}: {1}' -f $r.Label, ($bad -join '；'))
      $tail = @($r.Lines | Select-Object -Last 20)
      $null = $failureBlocks.Add((New-Object psobject -Property @{
        Title = ('{0} / {1}' -f $case.Name, $r.Label)
        Lines = [string[]]$tail
      }))
    }
  }

  $null = $rows.Add($row)
}

# ---------------------------------------------------------------------------
# Table
# ---------------------------------------------------------------------------

function Format-Cell([object]$Value) {
  if ($null -eq $Value) { return '—' }
  if ($Value -is [double]) { return (Format-Number $Value '0.00') }
  return [string]$Value
}

$header = @('素材', '默认', 'no-shell', '默认 ms', 'no-shell ms', 'PASS')
$table = @()
foreach ($row in $rows) {
  $table += ,@(
    $row.Name,
    $row.DefaultProvider,
    $row.NoShellProvider,
    (Format-Cell $row.DefaultMs),
    (Format-Cell $row.NoShellMs),
    $(if ($row.Ok) { 'PASS' } else { 'FAIL' })
  )
}

$widths = @()
for ($i = 0; $i -lt $header.Count; $i++) { $widths += (Get-DisplayWidth $header[$i]) }
foreach ($cells in $table) {
  for ($i = 0; $i -lt $cells.Count; $i++) {
    $w = Get-DisplayWidth ([string]$cells[$i])
    if ($w -gt $widths[$i]) { $widths[$i] = $w }
  }
}

$lineWidth = 0
for ($i = 0; $i -lt $widths.Count; $i++) { $lineWidth += $widths[$i] }
$lineWidth += 2 * ($widths.Count - 1)

Write-Output ''
Write-Output (Format-Row $header $widths)
foreach ($cells in $table) {
  Write-Output (Format-Row ([string[]]$cells) $widths)
}
Write-Output ('─' * $lineWidth)

$pass = @($rows | Where-Object { $_.Ok }).Count
$fail = @($rows | Where-Object { -not $_.Ok }).Count
$assets = $script:cases.Count

# Raw output of every failed round, then one line per failed row. A row can fail
# without a round block (a missing sample), so both sections are independent.
if ($failureBlocks.Count -gt 0) {
  foreach ($block in $failureBlocks) {
    Write-Output ''
    Write-Output ('!! {0}' -f $block.Title)
    foreach ($line in $block.Lines) { Write-Output ('  | ' + $line) }
  }
}

if ($fail -gt 0) {
  Write-Output ''
  Write-Output '失败明细：'
  foreach ($row in $rows) {
    if (-not $row.Ok) {
      foreach ($problem in $row.Problems) { Write-Output ('  [{0}] {1}' -f $row.Name, $problem) }
    }
  }
}

# One machine-readable line: health.ps1 parses this, the rest of the table is for
# humans. open_ms_max is informational only (no threshold).
$summary = [string]::Format(
  [System.Globalization.CultureInfo]::InvariantCulture,
  'provider-matrix: assets={0} pass={1} fail={2} rounds=2 runs={3} open_ms_max={4:0.00}',
  $assets, $pass, $fail, $runCount, $maxOpenMs)
Write-Output $summary

if ($fail -eq 0) {
  Write-Output ('provider 矩阵: PASS（{0}/{1} 素材 × 2 轮）' -f $pass, $assets)
  exit 0
}

Write-Output ('provider 矩阵: FAIL（{0}/{1} 素材通过）' -f $pass, $assets)
exit 1
