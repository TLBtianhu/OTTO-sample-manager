# One command: run the whole OTTO Lite verification gate and print one table.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\health.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\health.ps1 -Quick
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\health.ps1 -Release
#
# What it runs, in order:
#   1. zig build (debug, then release; -Release runs release only)
#   2. core / ports / app `zig build test`
#   3. verify-distribution.ps1 against the real %APPDATA% (it snapshots/restores)
#   4. bench.ps1 (-Big, six rows), scroll.ps1, mem.ps1
#   5. opacity.ps1
#   6. --demo / --demo-rescan / --demo-thumbs / --demo-transport
#   7. verify-minisign.js on the newest portable.zip + setup.exe in zig\dist
#
# -Quick keeps the pre-commit subset: builds + tests + distribution audit +
# signatures (bench / scroll / mem / opacity / self-checks are skipped).
# -Release skips the debug build; release is what ships.
#
# A sub-script failure is recorded and the run continues; the exit code is
# decided once at the end. A PASS row that fails -> exit 1. The charter's known
# unmet first-frame <= 100 ms row is reported as KNOWN-FAIL and does not fail
# the run. SKIP means "nothing to verify / prerequisite missing" and is not a
# failure (e.g. no artifacts under zig\dist yet).
#
# No window is shown and no focus is taken: every probe below uses the app's
# hidden/offscreen paths; this script only starts processes and reads files.
#
# This file is UTF-8 **with BOM** on purpose: Windows PowerShell 5.1 reads a
# BOM-less .ps1 as ANSI and would garble the Chinese table.

[CmdletBinding()]
param(
  [switch]$Release,
  [switch]$Quick,
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe',
  [string]$Samples = 'C:\src\otto-testkit\samples'
)

# Native tools write diagnostics to stderr; under 'Stop' Windows PowerShell
# turns those into terminating errors. Every exit code below is checked by hand.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:root = $PSScriptRoot
$script:appDir = Join-Path $script:root 'app'
$script:exe = Join-Path $script:appDir 'zig-out\bin\otto-lite.exe'
$script:distDir = Join-Path $script:root 'dist'
$script:rows = New-Object System.Collections.ArrayList
$script:clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:releaseBuildOk = $false

$script:powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $script:powershell)) { $script:powershell = 'powershell.exe' }

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$Text) {
  Write-Output ''
  Write-Output ('== {0} ==' -f $Text)
}

function Add-Row {
  param(
    [string]$Item,
    [string]$Result,
    [string]$Stat,
    [string]$Note = ''
  )
  $null = $script:rows.Add((New-Object psobject -Property @{
    Item = $Item
    Result = $Result
    Stat = $Stat
    Note = $Note
  }))
  $line = '  [{0}] {1}' -f $Result, $Stat
  if ($Note -and $Note.Length -gt 0) { $line += '  ' + $Note }
  Write-Output $line
}

function Write-FailureTail {
  param(
    [string[]]$Lines,
    [int]$Count = 25
  )
  $tail = @($Lines | Select-Object -Last $Count)
  Write-Output ('  --- 失败输出（末 {0} 行）---' -f $tail.Count)
  foreach ($line in $tail) { Write-Output ('  | ' + $line) }
  Write-Output '  ---'
}

# Display width: CJK / full-width characters occupy two console cells, so a
# plain string length pads Chinese headers wrong. Same ranges as
# verify-distribution.ps1.
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

function Print-Table {
  $header = @('项目', '结果', '关键数字', '备注')
  $widths = @()
  for ($i = 0; $i -lt $header.Count; $i++) { $widths += (Get-DisplayWidth $header[$i]) }
  foreach ($row in $script:rows) {
    $cells = @($row.Item, $row.Result, $row.Stat, $row.Note)
    for ($i = 0; $i -lt $cells.Count; $i++) {
      $width = Get-DisplayWidth $cells[$i]
      if ($width -gt $widths[$i]) { $widths[$i] = $width }
    }
  }
  # Keep the result column wide enough for KNOWN-FAIL.
  if ($widths[1] -lt 10) { $widths[1] = 10 }

  $lineWidth = 0
  for ($i = 0; $i -lt $widths.Count; $i++) { $lineWidth += $widths[$i] }
  $lineWidth += 2 * ($widths.Count - 1)

  Write-Output ''
  Write-Output (Format-Row $header $widths)
  foreach ($row in $script:rows) {
    Write-Output (Format-Row @($row.Item, $row.Result, $row.Stat, $row.Note) $widths)
  }
  Write-Output ('─' * $lineWidth)

  $pass = @($script:rows | Where-Object { $_.Result -eq 'PASS' }).Count
  $known = @($script:rows | Where-Object { $_.Result -eq 'KNOWN-FAIL' }).Count
  $fail = @($script:rows | Where-Object { $_.Result -eq 'FAIL' }).Count
  $skip = @($script:rows | Where-Object { $_.Result -eq 'SKIP' }).Count

  $total = @()
  $total += ('{0} PASS' -f $pass)
  if ($known -gt 0) { $total += ('{0} KNOWN-FAIL' -f $known) }
  if ($fail -gt 0) { $total += ('{0} FAIL' -f $fail) }
  if ($skip -gt 0) { $total += ('{0} SKIP' -f $skip) }
  Write-Output ('总计                 ' + ($total -join ' / '))
  Write-Output ('总耗时               {0:N1} s' -f $script:clock.Elapsed.TotalSeconds)
  if ($known -gt 0) {
    Write-Output 'KNOWN-FAIL = 宪章已知未达标项（冷启动→首帧 ≤ 100 ms），不算脚本失败。'
  }
}

# ---------------------------------------------------------------------------
# Child-process helpers
# ---------------------------------------------------------------------------

# Runs a sibling PowerShell script under Windows PowerShell 5.1 (the version the
# scripts target), merges stdout/stderr, and returns its exit code. All output is
# captured so the table stays readable; the tail is printed only on failure.
function Invoke-Child {
  param(
    [string]$ScriptPath,
    [string[]]$ChildArgs
  )
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $code = -1
  try {
    $lines = @(& $script:powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ChildArgs 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    })
    $code = $LASTEXITCODE
  } catch {
    $lines = @($_.Exception.Message)
    $code = -1
  }
  $watch.Stop()
  return (New-Object psobject -Property @{
    Code = $code
    Lines = [string[]]$lines
    Text = [string]::Join("`n", [string[]]$lines)
    Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
  })
}

# Runs a native exe (the app's demo switches), same capture rules as Invoke-Child.
function Invoke-Exe {
  param(
    [string]$ExePath,
    [string[]]$ChildArgs
  )
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $code = -1
  try {
    $lines = @(& $ExePath @ChildArgs 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    })
    $code = $LASTEXITCODE
  } catch {
    $lines = @($_.Exception.Message)
    $code = -1
  }
  $watch.Stop()
  return (New-Object psobject -Property @{
    Code = $code
    Lines = [string[]]$lines
    Text = [string]::Join("`n", [string[]]$lines)
    Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
  })
}

# Zig 0.17 caches a successful `zig build test` run step and does not replay the
# test output, so a second health run would show no count. The run step's cache
# entry is the small .zig-cache\h manifest that mentions the built test.exe;
# dropping only those forces the test executables to run again while the
# compiled artifacts stay cached. Nothing outside the build cache is touched.
function Reset-TestRunCache([string]$PkgDir) {
  $manifestDir = Join-Path $PkgDir '.zig-cache\h'
  if (-not (Test-Path -LiteralPath $manifestDir)) { return }
  Get-ChildItem -LiteralPath $manifestDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Length -gt 0 -and $_.Length -lt 4096) {
      try {
        $text = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::ASCII)
        if ($text -match 'test\.exe') {
          Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
      } catch {
        # A locked/renamed cache file must not abort the health run; the test
        # step would simply stay cached and the count check reports it.
      }
    }
  }
}

# ---------------------------------------------------------------------------
# 1. Builds
# ---------------------------------------------------------------------------

function Invoke-Build {
  param([bool]$ReleaseBuild)
  $item = if ($ReleaseBuild) { '构建 (release)' } else { '构建 (debug)' }
  Write-Step $item

  $buildArgs = @('build')
  if ($ReleaseBuild) { $buildArgs += '-Drelease=true' }
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $code = -1
  $lines = @()
  Push-Location $script:appDir
  try {
    $lines = @(& $Zig @buildArgs 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    })
    $code = $LASTEXITCODE
  } catch {
    $lines = @($_.Exception.Message)
    $code = -1
  } finally {
    Pop-Location
  }
  $watch.Stop()
  $seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)

  $hasExe = Test-Path -LiteralPath $script:exe
  $ok = ($code -eq 0 -and $hasExe)

  if ($ok) {
    $size = (Get-Item -LiteralPath $script:exe).Length
    Add-Row $item 'PASS' ('exe {0:N0} B' -f $size) ('{0:N1} s' -f $seconds)
    if ($ReleaseBuild) { $script:releaseBuildOk = $true }
  } else {
    $note = if ($code -ne 0) { 'zig build exit {0}' -f $code } else { 'zig build 未产出 exe' }
    Add-Row $item 'FAIL' '—' ('{0}；{1:N1} s' -f $note, $seconds)
    if ($ReleaseBuild) { $script:releaseBuildOk = $false }
    Write-FailureTail $lines
  }
}

# ---------------------------------------------------------------------------
# 2. Test suites
# ---------------------------------------------------------------------------

function Invoke-TestSuite {
  param([string]$Name)
  $item = '测试 {0}' -f $Name
  Write-Step $item

  $pkgDir = Join-Path $script:root $Name
  if (-not (Test-Path -LiteralPath $pkgDir)) {
    Add-Row $item 'FAIL' '—' ('缺少目录 {0}' -f $pkgDir)
    return
  }

  # The real-window ports tests check that the foreground window does not move.
  # An unrelated shell/notification change can fail that check once even though
  # the code is fine, so a failed attempt is retried once. A real regression
  # fails both attempts and still ends up FAIL below.
  $attempts = @()
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    Reset-TestRunCache $pkgDir
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $code = -1
    $lines = @()
    Push-Location $pkgDir
    try {
      $lines = @(& $Zig build test --summary all 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
      })
      $code = $LASTEXITCODE
    } catch {
      $lines = @($_.Exception.Message)
      $code = -1
    } finally {
      Pop-Location
    }
    $watch.Stop()
    $seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
    $text = [string]::Join("`n", [string[]]$lines)

    $match = [regex]::Match($text, '(\d+)/(\d+) tests passed')
    $passed = $null
    $total = $null
    if ($match.Success) {
      $passed = [int]$match.Groups[1].Value
      $total = [int]$match.Groups[2].Value
    }
    $ok = ($code -eq 0 -and $null -ne $passed -and $total -gt 0 -and $passed -eq $total)

    $attempts += (New-Object psobject -Property @{
      Ok = $ok
      Code = $code
      Passed = $passed
      Total = $total
      Seconds = $seconds
      Lines = [string[]]$lines
    })
    if ($ok) { break }
    if ($attempt -eq 1) {
      Write-Output '  首次未通过，重试一次（真实窗口测试对系统焦点敏感）'
      Write-FailureTail $lines 15
    }
  }

  $totalSeconds = 0.0
  foreach ($attemptResult in $attempts) { $totalSeconds += $attemptResult.Seconds }
  $totalSeconds = [math]::Round($totalSeconds, 1)
  $last = $attempts[$attempts.Count - 1]
  $retried = ($attempts.Count -gt 1)

  if ($last.Ok) {
    $note = 'debug；{0:N1} s' -f $totalSeconds
    if ($retried) { $note += '；首次失败后重试通过' }
    Add-Row $item 'PASS' ('{0}/{1}' -f $last.Passed, $last.Total) $note
  } elseif ($null -ne $last.Passed) {
    Add-Row $item 'FAIL' ('{0}/{1}' -f $last.Passed, $last.Total) ('2 次尝试均失败；exit {0}；{1:N1} s' -f $last.Code, $totalSeconds)
    Write-FailureTail $last.Lines 25
  } else {
    Add-Row $item 'FAIL' '—' ('2 次尝试均失败；exit {0}；未抓到 tests passed；{1:N1} s' -f $last.Code, $totalSeconds)
    Write-FailureTail $last.Lines 25
  }
}

# ---------------------------------------------------------------------------
# 3. Distribution audit
# ---------------------------------------------------------------------------

function Invoke-Audit {
  $item = '形态审计'
  Write-Step $item
  if (-not $script:releaseBuildOk) {
    Add-Row $item 'SKIP' '—' 'release 构建失败'
    return
  }

  $auditArgs = @('-SkipBuild', '-Samples', $Samples, '-Zig', $Zig)
  $result = Invoke-Child (Join-Path $script:root 'verify-distribution.ps1') $auditArgs
  $text = $result.Text

  $passChecks = ([regex]::Matches($text, '\[PASS\]')).Count
  $failChecks = ([regex]::Matches($text, '\[FAIL\]')).Count
  $formPass = ([regex]::Matches($text, '(?m)^(dev|portable|installed(?:\([^)]*\))?)\s+[^\r\n]*\bPASS\s*$')).Count
  $formFail = ([regex]::Matches($text, '(?m)^(dev|portable|installed(?:\([^)]*\))?)\s+[^\r\n]*\bFAIL\s*$')).Count

  $ok = ($result.Code -eq 0 -and $failChecks -eq 0 -and $formFail -eq 0 -and $formPass -eq 3)
  if ($ok) {
    Add-Row $item 'PASS' ('{0} checks' -f $passChecks) ('dev / portable / installed(real)；{0:N1} s' -f $result.Seconds)
  } else {
    $stat = '{0} PASS / {1} FAIL' -f $passChecks, $failChecks
    Add-Row $item 'FAIL' $stat ('exit {0}；形态 PASS {1}/3；{2:N1} s' -f $result.Code, $formPass, $result.Seconds)
    Write-FailureTail $result.Lines 40
  }
}

# ---------------------------------------------------------------------------
# 4. Performance
# ---------------------------------------------------------------------------

function Invoke-Bench {
  $item = '性能 bench'
  Write-Step $item
  if (-not $script:releaseBuildOk) {
    Add-Row $item 'SKIP' '—' 'release 构建失败'
    return
  }

  $benchArgs = @('-Big', '-Release', '-NoBuild', '-Samples', $Samples, '-Zig', $Zig)
  $result = Invoke-Child (Join-Path $script:root 'bench.ps1') $benchArgs
  $text = $result.Text

  $summary = [regex]::Match($text, 'PASS=(\d+)\s+FAIL=(\d+)\s+SKIP=(\d+)')
  if (-not $summary.Success) {
    Add-Row $item 'FAIL' '—' ('bench exit {0}；没有 PASS/FAIL 汇总；{1:N1} s' -f $result.Code, $result.Seconds)
    Write-FailureTail $result.Lines 40
    return
  }

  $pass = [int]$summary.Groups[1].Value
  $fail = [int]$summary.Groups[2].Value
  $skip = [int]$summary.Groups[3].Value

  $firstFrame = [regex]::Match($text, '冷启动→首帧\s+([0-9.]+)\s*ms')
  $failedMetrics = @()
  foreach ($line in $result.Lines) {
    if ($line -match '^\s*(库加载|冷启动→首帧|常驻内存|搜索延迟|缩略图|音频起播)\s') {
      $metric = $Matches[1]
      if ($line -match '\bFAIL\b') { $failedMetrics += $metric }
    }
  }

  $stat = '{0} PASS / {1} FAIL' -f $pass, $fail
  if ($skip -gt 0) { $stat += (' / {0} SKIP' -f $skip) }
  if ($firstFrame.Success) { $stat += ('  首帧 {0} ms' -f $firstFrame.Groups[1].Value) }

  # The charter's known unmet item is the first-frame budget. Everything else
  # failing is a real regression and must turn the row FAIL.
  $knownMetrics = @('冷启动→首帧')
  $onlyKnown = ($failedMetrics.Count -eq 1)
  foreach ($metric in $failedMetrics) {
    if ($knownMetrics -notcontains $metric) { $onlyKnown = $false }
  }

  if ($fail -eq 0 -and $result.Code -eq 0) {
    Add-Row $item 'PASS' $stat ('六项全部达标；{0:N1} s' -f $result.Seconds)
  } elseif ($fail -eq 1 -and $onlyKnown) {
    Add-Row $item 'KNOWN-FAIL' ($stat + '（目标 100）') ('首帧 ≤100 ms 为宪章已知未达标项；{0:N1} s' -f $result.Seconds)
  } else {
    $bad = @($failedMetrics | Select-Object -Unique)
    if ($bad.Count -gt 0) {
      $note = '未达标：{0}；{1:N1} s' -f ($bad -join '、'), $result.Seconds
    } else {
      $note = 'exit {0}；{1:N1} s' -f $result.Code, $result.Seconds
    }
    Add-Row $item 'FAIL' $stat $note
    Write-FailureTail $result.Lines 40
  }
}

function Invoke-Scroll {
  $item = '滚动'
  Write-Step $item
  if (-not $script:releaseBuildOk) {
    Add-Row $item 'SKIP' '—' 'release 构建失败'
    return
  }

  $scrollArgs = @('-Release', '-NoBuild', '-Samples', $Samples, '-Zig', $Zig)
  $result = Invoke-Child (Join-Path $script:root 'scroll.ps1') $scrollArgs
  $text = $result.Text

  $gdi = [regex]::Match($text, '(?m)^\s*gdi\s+fps=\s*([0-9.]+)[^\r\n]*?[ \t]+(PASS|FAIL)[ \t]*$')
  $d3d = [regex]::Match($text, '(?m)^\s*d3d\s+fps=\s*([0-9.]+)[^\r\n]*?[ \t]+(PASS|FAIL)[ \t]*$')

  if (-not $gdi.Success) {
    Add-Row $item 'FAIL' '—' ('scroll exit {0}；没有 gdi 汇总；{1:N1} s' -f $result.Code, $result.Seconds)
    Write-FailureTail $result.Lines 40
    return
  }

  $fps = [double]$gdi.Groups[1].Value
  $verdict = $gdi.Groups[2].Value
  $stat = '{0:N1} fps' -f $fps
  $note = 'gdi（宪章口径，目标 60）'
  if ($d3d.Success) {
    $note += ('；d3d {0:N1} {1}' -f [double]$d3d.Groups[1].Value, $d3d.Groups[2].Value)
  }

  if ($verdict -eq 'PASS' -and $fps -ge 60) {
    Add-Row $item 'PASS' $stat ($note + ('；{0:N1} s' -f $result.Seconds))
  } else {
    Add-Row $item 'FAIL' $stat ($note + ('；未达 60 fps；{0:N1} s' -f $result.Seconds))
    Write-FailureTail $result.Lines 40
  }
}

function Invoke-Mem {
  $item = '内存'
  Write-Step $item
  if (-not $script:releaseBuildOk) {
    Add-Row $item 'SKIP' '—' 'release 构建失败'
    return
  }

  $memArgs = @('-Release', '-NoBuild', '-Samples', $Samples, '-Zig', $Zig)
  $result = Invoke-Child (Join-Path $script:root 'mem.ps1') $memArgs
  $text = $result.Text

  $on = [regex]::Match($text, '(?m)^\s*isolation-on\s+ws=\s*([0-9.]+)\s+private=\s*([0-9.]+)')
  $off = [regex]::Match($text, '(?m)^\s*isolation-off\s+ws=\s*([0-9.]+)\s+private=\s*([0-9.]+)')

  if (-not $on.Success) {
    Add-Row $item 'FAIL' '—' ('mem exit {0}；没有 isolation-on 行；{1:N1} s' -f $result.Code, $result.Seconds)
    Write-FailureTail $result.Lines 40
    return
  }

  $ws = [double]$on.Groups[1].Value
  $private = [double]$on.Groups[2].Value
  $stat = '{0:N1} MiB（目标 50）' -f $ws
  $note = 'private {0:N1}' -f $private
  if ($off.Success) { $note += ('；isolation-off {0:N1}' -f [double]$off.Groups[1].Value) }
  $note += ('；{0:N1} s' -f $result.Seconds)

  if ($ws -le 50.0) {
    Add-Row $item 'PASS' $stat $note
  } else {
    Add-Row $item 'FAIL' $stat ($note + '；超出宪章目标')
    Write-FailureTail $result.Lines 40
  }
}

# ---------------------------------------------------------------------------
# 5. Opacity
# ---------------------------------------------------------------------------

function Invoke-Opacity {
  $item = '透明度'
  Write-Step $item
  if (-not $script:releaseBuildOk) {
    Add-Row $item 'SKIP' '—' 'release 构建失败'
    return
  }

  $opacityArgs = @('-Release', '-NoBuild', '-Zig', $Zig)
  # Same foreground-window sensitivity as the ports tests: retry a failed
  # attempt once, but let a real failure fail both attempts.
  $attempts = @()
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    $result = Invoke-Child (Join-Path $script:root 'opacity.ps1') $opacityArgs
    $match = [regex]::Match($result.Text, '(\d+) checks, (\d+) passed, (\d+) failed')
    $checks = $null
    $passed = $null
    $failed = $null
    $ok = $false
    if ($match.Success) {
      $checks = [int]$match.Groups[1].Value
      $passed = [int]$match.Groups[2].Value
      $failed = [int]$match.Groups[3].Value
      $ok = ($result.Code -eq 0 -and $failed -eq 0 -and $checks -gt 0 -and $passed -eq $checks)
    }
    $attempts += (New-Object psobject -Property @{
      Ok = $ok
      Code = $result.Code
      Checks = $checks
      Passed = $passed
      Failed = $failed
      Seconds = $result.Seconds
      Lines = [string[]]$result.Lines
    })
    if ($ok) { break }
    if ($attempt -eq 1) {
      Write-Output '  首次未通过，重试一次（前台窗口检查对系统焦点敏感）'
      Write-FailureTail $result.Lines 20
    }
  }

  $totalSeconds = 0.0
  foreach ($attemptResult in $attempts) { $totalSeconds += $attemptResult.Seconds }
  $totalSeconds = [math]::Round($totalSeconds, 1)
  $last = $attempts[$attempts.Count - 1]
  $retried = ($attempts.Count -gt 1)

  if ($last.Ok) {
    $note = '真实隐藏窗口；{0:N1} s' -f $totalSeconds
    if ($retried) { $note += '；首次失败后重试通过' }
    Add-Row $item 'PASS' ('{0}/{1}' -f $last.Passed, $last.Checks) $note
  } elseif ($null -ne $last.Passed) {
    Add-Row $item 'FAIL' ('{0}/{1}' -f $last.Passed, $last.Checks) ('failed {0}；exit {1}；2 次尝试；{2:N1} s' -f $last.Failed, $last.Code, $totalSeconds)
    Write-FailureTail $last.Lines 25
  } else {
    Add-Row $item 'FAIL' '—' ('opacity exit {0}；没有 checks 汇总；2 次尝试；{1:N1} s' -f $last.Code, $totalSeconds)
    Write-FailureTail $last.Lines 25
  }
}

# ---------------------------------------------------------------------------
# 6. Demo self-checks
# ---------------------------------------------------------------------------

function Invoke-SelfChecks {
  $item = '自检'
  Write-Step $item
  if (-not $script:releaseBuildOk) {
    Add-Row $item 'SKIP' '—' 'release 构建失败'
    return
  }

  $demoRoot = Join-Path $env:TEMP 'otto-health-demo'
  if (Test-Path -LiteralPath $demoRoot) {
    Remove-Item -LiteralPath $demoRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  New-Item -ItemType Directory -Force -Path $demoRoot | Out-Null
  foreach ($name in @('watch', 'rescan', 'thumbs')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $demoRoot $name) | Out-Null
  }

  $cases = @(
    @{ Label = 'watch';     Args = @('--demo', (Join-Path $demoRoot 'watch'));                   Token = 'demo: OK' },
    @{ Label = 'rescan';    Args = @('--demo-rescan', (Join-Path $demoRoot 'rescan'));           Token = 'demo-rescan: OK' },
    @{ Label = 'thumbs';    Args = @('--demo-thumbs', (Join-Path $demoRoot 'thumbs'));           Token = 'demo-thumbs: OK' },
    @{ Label = 'transport'; Args = @('--demo-transport');                                        Token = 'demo-transport: OK' }
  )

  $failed = @()
  foreach ($case in $cases) {
    $result = Invoke-Exe $script:exe $case.Args
    $ok = ($result.Code -eq 0 -and $result.Text -like ('*' + $case.Token + '*'))
    if (-not $ok) {
      $failed += $case.Label
      Write-Output ('  [FAIL] {0}（exit {1}）' -f $case.Label, $result.Code)
      Write-FailureTail $result.Lines 15
    }
  }

  if ($failed.Count -eq 0) {
    Add-Row $item 'PASS' '4/4' 'watch / rescan / thumbs / transport'
  } else {
    Add-Row $item 'FAIL' ('{0}/4' -f (4 - $failed.Count)) ('失败：{0}' -f ($failed -join '、'))
  }

  Remove-Item -LiteralPath $demoRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 7. Signatures (newest zig\dist artifacts)
# ---------------------------------------------------------------------------

function Invoke-Signing {
  $item = '签名'
  Write-Step $item

  if (-not (Test-Path -LiteralPath $script:distDir)) {
    Add-Row $item 'SKIP' '—' 'zig/dist 无产物（先跑 zig\package.ps1）'
    return
  }

  $zip = Get-ChildItem -LiteralPath $script:distDir -File -Filter '*portable.zip' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $setup = Get-ChildItem -LiteralPath $script:distDir -File -Filter '*setup.exe' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

  $artifacts = @()
  if ($null -ne $zip) { $artifacts += $zip }
  if ($null -ne $setup) { $artifacts += $setup }

  if ($artifacts.Count -eq 0) {
    Add-Row $item 'SKIP' '—' 'zig/dist 无 portable.zip / setup.exe'
    return
  }

  $node = Get-Command node -ErrorAction SilentlyContinue
  $verifyScript = Join-Path $script:root 'tools\verify-minisign.js'
  $publicKey = Join-Path $script:root 'keys\otto-lite.key.pub'
  if ($null -eq $node) {
    Add-Row $item 'FAIL' '—' '找不到 node（verify-minisign.js 需要 Node.js）'
    return
  }
  if (-not (Test-Path -LiteralPath $publicKey)) {
    Add-Row $item 'FAIL' '—' ('缺少公钥 {0}' -f $publicKey)
    return
  }
  if (-not (Test-Path -LiteralPath $verifyScript)) {
    Add-Row $item 'FAIL' '—' ('缺少校验脚本 {0}' -f $verifyScript)
    return
  }

  $versions = @()
  $kinds = @()
  $bad = @()
  foreach ($artifact in $artifacts) {
    if ($artifact.Name -like '*portable.zip') { $kinds += 'zip' } else { $kinds += 'setup' }
    $versionMatch = [regex]::Match($artifact.Name, '^otto-lite-(\d+\.\d+\.\d+)-(portable\.zip|setup\.exe)$')
    if ($versionMatch.Success) { $versions += $versionMatch.Groups[1].Value }

    $sigPath = $artifact.FullName + '.sig'
    if (-not (Test-Path -LiteralPath $sigPath)) {
      $bad += ('{0}（缺 .sig）' -f $artifact.Name)
      continue
    }

    $check = $null
    try {
      $check = @(& $node.Source $verifyScript $publicKey $sigPath $artifact.FullName 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
      })
      $verifyCode = $LASTEXITCODE
    } catch {
      $check = @($_.Exception.Message)
      $verifyCode = -1
    }
    if ($verifyCode -ne 0) {
      $bad += $artifact.Name
      Write-Output ('  [FAIL] {0} 签名校验失败（exit {1}）' -f $artifact.Name, $verifyCode)
      Write-FailureTail $check 15
    }
  }

  $stat = '{0} {1}' -f (($versions | Select-Object -Unique) -join '/'), ($kinds -join '+')
  if ($stat.Trim() -eq '') { $stat = '—' }

  if ($bad.Count -eq 0) {
    $note = 'minisign ED 校验通过'
    $missing = @()
    if ($null -eq $zip) { $missing += 'portable.zip' }
    if ($null -eq $setup) { $missing += 'setup.exe' }
    if ($missing.Count -gt 0) { $note += ('；缺 {0}' -f ($missing -join '、')) }
    Add-Row $item 'PASS' $stat $note
  } else {
    Add-Row $item 'FAIL' $stat ('校验失败：{0}' -f ($bad -join '、'))
  }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Output 'OTTO Lite 健康检查'
Write-Output ('zig: {0}' -f $Zig)
if ($Quick) {
  Write-Output '模式: -Quick（跳过 bench / scroll / mem / 透明度 / 自检）'
} elseif ($Release) {
  Write-Output '模式: 完整（-Release：只构建 release）'
} else {
  Write-Output '模式: 完整（debug + release）'
}

if (-not (Test-Path -LiteralPath $Zig)) {
  Write-Output ('致命错误：找不到 zig：{0}' -f $Zig)
  exit 1
}

if (-not $Release) { Invoke-Build $false }
Invoke-Build $true

Invoke-TestSuite 'core'
Invoke-TestSuite 'ports'
Invoke-TestSuite 'app'

Invoke-Audit

if (-not $Quick) {
  Invoke-Bench
  Invoke-Scroll
  Invoke-Mem
  Invoke-Opacity
  Invoke-SelfChecks
}

Invoke-Signing

$script:clock.Stop()
Print-Table

$failCount = @($script:rows | Where-Object { $_.Result -eq 'FAIL' }).Count
$exitCode = if ($failCount -gt 0) { 1 } else { 0 }
exit $exitCode
