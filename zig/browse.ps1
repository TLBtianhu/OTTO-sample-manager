# 目录浏览验收闸门：原 Stage 0/分页 18 行 + Stage 1 导航 9 行 + 地址栏 11 行（38 项），
# 再加按需补全 / 路径健壮性 / Explorer 键 11 行（总计 49 项）。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\browse.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\browse.ps1 -Recreate -SkipScroll
#
# 跑什么（全部无窗口 / 隐藏窗口，不抢焦点）：
#   1. 1 万文件目录的首屏        --browse-probe，first_page_ms < 100
#   2. 10 万文件目录             entries=50000 truncated=true rss_mib < 120，不崩
#   3. 选中即预览 mp3/flac/mp4   首次预览 < 150/150/200 ms；同一文件用 --preview 对照
#   4. 滚动                      --bench-scroll <目录> 的 fps >= 60
#   5. 零写入                    probe 的 writes=0 + 源目录前后快照（名字+大小+mtime）完全一致
#   6. 外部改目录                拷 50 个文件进当前目录：watch 探针收到事件、行数 +50，
#                                并且 UI 快照那一帧的 matched 数字跟着涨
#   7. 删除选中文件              选中行标"已删除"、选中项落到相邻行、不崩
#   8. 权限拒绝                  打不开的文件仍在列表里（unreadable 计数），打不开的目录不崩
#   9. 库模式未受影响            --filter 仍然读得到 fixtures 的 2000 条
#                                （完整闸门是 zig\health.ps1 -Quick：10 PASS + 三套测试）
#  10. 分页（10 万）             --pages=3：能拿到 >5 万条且 truncated=false；或按 90 MiB
#                                内存上限拒绝、剩余条数具名。峰值必须 ≤ 90 MiB
#  11. 每行开销                 报告里的实测 bytes_per_row（预算判断用的就是它）
#  12. 页大小（--browse-limit）  1 万目录、1000/页：首批 1000，点两次 = 3000，还有更多
#  13. 重扫期间不丢              --force-rescan 暂停窗口里拷 50 个文件：最终行数 = 磁盘 250
#  14. 目录消失再回来            --vanish-then-return：unavailable 翻转；交互后行数 = 磁盘
#  15. 内存预算拒绝              页大小 20 万时第二次「加载更多」被 90 MiB 预算拒绝，
#                                拒绝后仍数清剩余（不悄悄停）
#
# 约定（zig/CONVENTIONS.md）：不弹窗、不抢焦点；子进程一律 CreateNoWindow + 重定向
# 两个流；拼接好命令行**先回显再执行**；形参一律不用 `$args` 之类的自动变量。
#
# 本文件是 UTF-8 **带 BOM**（Windows PowerShell 5.1 读无 BOM 的 .ps1 会按 ANSI 解，中文表会花）。

[CmdletBinding()]
param(
  [string]$Exe = (Join-Path $PSScriptRoot 'app\zig-out\bin\otto-lite.exe'),
  [string]$Root = (Join-Path $env:TEMP 'otto-browse-accept'),
  [switch]$Recreate,
  [switch]$SkipScroll,
  [switch]$SkipSnapshot,
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:rows = New-Object System.Collections.ArrayList
$script:clock = [System.Diagnostics.Stopwatch]::StartNew()
# 10 万目录的分页探针只跑一次：分页 / 每行开销两行共用这份输出。
$script:hundredKPage = $null

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

function Add-Row {
  param([string]$Item, [string]$Result, [string]$Stat, [string]$Note = '')
  $null = $script:rows.Add((New-Object psobject -Property @{
    Item = $Item
    Result = $Result
    Stat = $Stat
    Note = $Note
  }))
  $line = '  [{0}] {1}' -f $Result, $Stat
  if ($Note.Length -gt 0) { $line += '  ' + $Note }
  Write-Output $line
}

function Write-Step([string]$Text) {
  Write-Output ''
  Write-Output ('== {0} ==' -f $Text)
}

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
        ($code -ge 0xFFE0 -and $code -le 0xFFE6)) { $width += 2 } else { $width += 1 }
  }
  return $width
}

function Format-Row {
  param([string[]]$Cells, [int[]]$Widths)
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
  if ($widths[1] -lt 6) { $widths[1] = 6 }

  Write-Output ''
  Write-Output (Format-Row $header $widths)
  foreach ($row in $script:rows) {
    Write-Output (Format-Row @($row.Item, $row.Result, $row.Stat, $row.Note) $widths)
  }
  $pass = @($script:rows | Where-Object { $_.Result -eq 'PASS' }).Count
  $fail = @($script:rows | Where-Object { $_.Result -eq 'FAIL' }).Count
  $skip = @($script:rows | Where-Object { $_.Result -eq 'SKIP' }).Count
  $total = @('{0} PASS' -f $pass)
  if ($fail -gt 0) { $total += ('{0} FAIL' -f $fail) }
  if ($skip -gt 0) { $total += ('{0} SKIP' -f $skip) }
  Write-Output (('-' * 60))
  Write-Output ('总计  ' + ($total -join ' / ') + ('    {0:N1} s' -f $script:clock.Elapsed.TotalSeconds))
}

# ---------------------------------------------------------------------------
# 子进程：CreateNoWindow + 两个流都读（CONVENTIONS 第 2 条）
# ---------------------------------------------------------------------------

function Invoke-Exe {
  param([string]$ExePath, [string[]]$ExeArgs)
  $arguments = ($ExeArgs -join ' ')
  Write-Host ('  $ "{0}" {1}' -f $ExePath, $arguments)

  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $code = -1
  $lines = @()
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $text = [string]$stdout.Result + [string]$stderr.Result
    $lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
    $code = $proc.ExitCode
    $proc.Dispose()
  } catch {
    $lines = @($_.Exception.Message)
    $code = -1
  }
  $watch.Stop()
  return (New-Object psobject -Property @{
    Code = $code
    Lines = [string[]]$lines
    Text = [string]::Join("`n", [string[]]$lines)
    Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
  })
}

# 起一个探针、在它跑着的时候执行 `$Action`、再收尾。用于"外部改目录"与"删除选中行"。
function Invoke-ExeWhile {
  param([string]$ExePath, [string[]]$ExeArgs, [int]$DelayMs, [scriptblock]$Action)
  $arguments = ($ExeArgs -join ' ')
  Write-Host ('  $ "{0}" {1}   (+ 外部动作)' -f $ExePath, $arguments)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ExePath
  $psi.Arguments = $arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEndAsync()
  $stderr = $proc.StandardError.ReadToEndAsync()
  Start-Sleep -Milliseconds $DelayMs
  try { & $Action } catch { Write-Output ('  外部动作失败：' + $_.Exception.Message) }
  $proc.WaitForExit()
  $text = [string]$stdout.Result + [string]$stderr.Result
  $code = $proc.ExitCode
  $proc.Dispose()
  return (New-Object psobject -Property @{
    Code = $code
    Text = $text
    Lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
  })
}

# ---------------------------------------------------------------------------
# 目录准备
# ---------------------------------------------------------------------------

function New-FileSet {
  param([string]$Dir, [int]$Count, [string]$Prefix)
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $bytes = [System.Text.Encoding]::ASCII.GetBytes('otto-browse')
  $exts = @('wav', 'png', 'txt')
  for ($i = 0; $i -lt $Count; $i++) {
    $name = '{0}{1:d6}.{2}' -f $Prefix, $i, $exts[$i % 3]
    [System.IO.File]::WriteAllBytes((Join-Path $Dir $name), $bytes)
  }
}

function Initialize-Fixtures {
  param([string]$Base, [bool]$Recreate)
  $needed = @('10k', '100k', 'preview', 'watch', 'deny', 'empty')
  $missing = $false
  foreach ($name in $needed) {
    if (-not (Test-Path -LiteralPath (Join-Path $Base $name))) { $missing = $true }
  }
  if ($Recreate -or $missing) {
    Write-Output ('  造夹具：{0}（10k / 100k / preview / watch / deny / empty）' -f $Base)
    if (Test-Path -LiteralPath $Base) { Remove-Item -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $Base | Out-Null
    New-FileSet (Join-Path $Base '10k') 10000 'a'
    New-FileSet (Join-Path $Base '100k') 100000 'b'
    New-FileSet (Join-Path $Base 'watch') 200 'w'
    New-Item -ItemType Directory -Force -Path (Join-Path $Base 'preview') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Base 'deny') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Base 'empty') | Out-Null
    $samples = Join-Path $PSScriptRoot '..\..\otto-testkit\samples'
    if (Test-Path -LiteralPath $samples) {
      Copy-Item (Join-Path $samples 'viper.mp3') (Join-Path $Base 'preview\viper.mp3') -Force
      Copy-Item (Join-Path $samples 'tone_660.flac') (Join-Path $Base 'preview\tone_660.flac') -Force
      Copy-Item (Join-Path $samples 'rabbit320.mp4') (Join-Path $Base 'preview\rabbit320.mp4') -Force
    } else {
      Write-Output ('  警告：找不到素材目录 {0}（预览用例会 SKIP）' -f $samples)
    }
  }
}

# ---------------------------------------------------------------------------
# 快照：名字 + 大小 + mtime
# ---------------------------------------------------------------------------

function Get-DirSnapshot {
  param([string]$Dir)
  $map = @{}
  foreach ($item in (Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue)) {
    $map[$item.Name] = '{0}:{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
  }
  return $map
}

function Compare-DirSnapshot {
  param($Before, $After)
  $changed = 0
  foreach ($key in $Before.Keys) {
    if (-not $After.ContainsKey($key)) { $changed += 1; continue }
    if ($After[$key] -ne $Before[$key]) { $changed += 1 }
  }
  foreach ($key in $After.Keys) {
    if (-not $Before.ContainsKey($key)) { $changed += 1 }
  }
  return $changed
}

# ---------------------------------------------------------------------------
# 1. 1 万文件目录的首屏
# ---------------------------------------------------------------------------

function Invoke-FirstPage {
  Write-Step '1. 1 万文件目录的首屏'
  $dir = Join-Path $Root '10k'
  $r = Invoke-Exe $Exe @('--browse-probe', ('"{0}"' -f $dir))
  $m = [regex]::Match($r.Text, 'entries=(\d+) truncated=(\w+) first_page_ms=([0-9.]+) enum_ms=([0-9.]+)')
  if (-not $m.Success) {
    Add-Row '1万首屏' 'FAIL' '—' ('没有 probe 汇总行；exit {0}' -f $r.Code)
    return
  }
  $entries = [int]$m.Groups[1].Value
  $first = [double]$m.Groups[3].Value
  $ok = ($r.Code -eq 0 -and $entries -eq 10000 -and $first -lt 100)
  $note = '判据 first_page_ms < 100；enum_ms {0}' -f $m.Groups[4].Value
  if ($ok) {
    Add-Row '1万首屏' 'PASS' ('first_page_ms={0:N2}' -f $first) $note
  } else {
    Add-Row '1万首屏' 'FAIL' ('first_page_ms={0:N2} entries={1}' -f $first, $entries) $note
  }
}

# ---------------------------------------------------------------------------
# 2. 10 万文件目录
# ---------------------------------------------------------------------------

function Invoke-HundredThousand {
  Write-Step '2. 10 万文件目录'
  $dir = Join-Path $Root '100k'
  $r = Invoke-Exe $Exe @('--browse-probe', ('"{0}"' -f $dir))
  $m = [regex]::Match($r.Text, 'entries=(\d+) truncated=(\w+) first_page_ms=([0-9.]+) enum_ms=([0-9.]+) rss_mib=([0-9.]+)')
  if (-not $m.Success) {
    Add-Row '10万文件' 'FAIL' '—' ('没有 probe 汇总行；exit {0}' -f $r.Code)
    return
  }
  $entries = [int]$m.Groups[1].Value
  $truncated = $m.Groups[2].Value -eq 'true'
  $rss = [double]$m.Groups[5].Value
  $ok = ($r.Code -eq 0 -and $entries -eq 50000 -and $truncated -and $rss -lt 120)
  $stat = 'entries={0} truncated={1} rss_mib={2:N2}' -f $entries, ($m.Groups[2].Value), $rss
  $note = '判据 truncated=true、rss_mib < 120（上限 50000 条 → 内存与条目数的关系）'
  if ($ok) { Add-Row '10万文件' 'PASS' $stat $note } else { Add-Row '10万文件' 'FAIL' $stat $note }
}

# ---------------------------------------------------------------------------
# 3. 选中即预览（mp3 / flac / mp4）
# ---------------------------------------------------------------------------

function Invoke-PreviewLatency {
  Write-Step '3. 选中即预览（mp3 / flac / mp4）'
  $dir = Join-Path $Root 'preview'
  $cases = @(
    @{ Name = 'viper.mp3'; Limit = 150 },
    @{ Name = 'tone_660.flac'; Limit = 150 },
    @{ Name = 'rabbit320.mp4'; Limit = 200 }
  )
  $parts = @()
  $allOk = $true
  foreach ($case in $cases) {
    $path = Join-Path $dir $case.Name
    if (-not (Test-Path -LiteralPath $path)) {
      $parts += ('{0} SKIP' -f $case.Name)
      $allOk = $false
      continue
    }
    # 每个文件三次取**中位数**：首次预览和首帧一样是"有一次被测到就超"的指标，
    # 单次采样会被机器负载（上一行刚跑了 10 万条枚举）抬高。宪章的首帧判据用
    # p50/p95 也是同一个理由（PERF.md：单次 100±5 ms 是系统自身的抖动）。
    $samples = @()
    $provider = '?'
    for ($round = 0; $round -lt 3; $round++) {
      $r = Invoke-Exe $Exe @('--browse-probe', ('"{0}"' -f $dir), ('--preview-first={0}' -f $case.Name))
      $pm = [regex]::Match($r.Text, 'preview_ms=([0-9.]+) arrived=(\w+) provider=(\S+)')
      if (-not $pm.Success) { Add-Row ('预览 {0}' -f $case.Name) 'FAIL' '—' ('没有 preview 行；exit {0}' -f $r.Code); $allOk = $false; continue }
      $samples += [double]$pm.Groups[1].Value
      $provider = $pm.Groups[3].Value
    }
    if ($samples.Count -eq 0) { continue }
    $sorted = @($samples | Sort-Object)
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)]
    $min = $sorted[0]
    $max = $sorted[$sorted.Count - 1]
    # 同一条路径的 --preview 对照（open_ms 是注册表 + 解码的墙钟）。
    $ref = Invoke-Exe $Exe @('--preview', ('"{0}"' -f $path))
    $rm = [regex]::Match($ref.Text, 'open_ms=([0-9.]+)')
    $refMs = if ($rm.Success) { [double]$rm.Groups[1].Value } else { -1 }
    $ok = ($median -lt [double]$case.Limit)
    if (-not $ok) { $allOk = $false }
    $parts += ('{0} {1:N1}/{2}ms' -f $case.Name.Substring(0, 3), $median, $case.Limit)
    Add-Row ('预览 {0}' -f $case.Name) ($(if ($ok) { 'PASS' } else { 'FAIL' })) ('中位 {0:N1} ms（限 {1}；{2:N1}–{3:N1}）' -f $median, $case.Limit, $min, $max) ('provider={0}；对照 --preview open_ms={1:N1}' -f $provider, $refMs)
  }
  return $allOk
}

# ---------------------------------------------------------------------------
# 4. 滚动
# ---------------------------------------------------------------------------

function Invoke-Scroll {
  Write-Step '4. 滚动（浏览模式下的 1 万行）'
  if ($SkipScroll) { Add-Row '滚动' 'SKIP' '—' '传了 -SkipScroll'; return }
  $dir = Join-Path $Root '10k'
  $r = Invoke-Exe $Exe @('--bench-scroll', ('"{0}"' -f $dir), '--frames', '300')
  $m = [regex]::Match($r.Text, 'scroll-bench: summary mode=gdi fps=([0-9.]+) p50=([0-9.]+) p95=([0-9.]+)')
  $mm = [regex]::Match($r.Text, 'matched=(\d+)/')
  if (-not $m.Success) {
    Add-Row '滚动' 'FAIL' '—' ('没有 scroll-bench 汇总行；exit {0}' -f $r.Code)
    return
  }
  $fps = [double]$m.Groups[1].Value
  $ok = ($r.Code -eq 0 -and $fps -ge 60)
  $note = '判据 fps >= 60；帧间隔 p50={0} p95={1} ms' -f $m.Groups[2].Value, $m.Groups[3].Value
  if ($mm.Success) { $note += ('；视图行数 {0}' -f $mm.Groups[1].Value) }
  if ($ok) { Add-Row '滚动' 'PASS' ('{0:N2} fps' -f $fps) $note } else { Add-Row '滚动' 'FAIL' ('{0:N2} fps' -f $fps) $note }
}

# ---------------------------------------------------------------------------
# 5. 零写入
# ---------------------------------------------------------------------------

function Invoke-ZeroWrite {
  Write-Step '5. 零写入（源目录前后快照）'
  $dir = Join-Path $Root '10k'
  $before = Get-DirSnapshot $dir
  $r = Invoke-Exe $Exe @('--browse-probe', ('"{0}"' -f $dir))
  $after = Get-DirSnapshot $dir
  $diff = Compare-DirSnapshot $before $after
  $m = [regex]::Match($r.Text, 'writes=(\d+)')
  $probeWrites = if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }
  $ok = ($r.Code -eq 0 -and $probeWrites -eq 0 -and $diff -eq 0 -and $before.Count -eq 10000)
  $stat = 'writes={0} 快照差异={1}（{2} 个条目）' -f $probeWrites, $diff, $before.Count
  $note = '判据 writes=0 且 名字+大小+mtime 完全一致'
  if ($ok) { Add-Row '零写入' 'PASS' $stat $note } else { Add-Row '零写入' 'FAIL' $stat $note }
}

# ---------------------------------------------------------------------------
# 6. 外部改目录（拷 50 个文件）
# ---------------------------------------------------------------------------

function Invoke-ExternalChange {
  Write-Step '6. 外部改目录（拷 50 个文件）'
  $dir = Join-Path $Root 'watch'
  # 每次从 200 个文件的干净状态开始：先清掉上一轮拷进去的 50 个。
  foreach ($name in @(Get-ChildItem -LiteralPath $dir -File -Filter 'copy-*' -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $name.FullName -Force
  }
  $samples = Join-Path $PSScriptRoot '..\..\otto-testkit\samples'
  $source = Join-Path $samples 'img00.png'
  if (-not (Test-Path -LiteralPath $source)) {
    Add-Row '外部改目录' 'SKIP' '—' ('找不到素材 {0}' -f $source)
    return
  }
  $action = {
    for ($i = 0; $i -lt 50; $i++) {
      Copy-Item -LiteralPath $source -Destination (Join-Path $dir ('copy-{0:d3}.png' -f $i)) -Force
    }
  }.GetNewClosure()
  $r = Invoke-ExeWhile $Exe @('--browse-watch-probe', ('"{0}"' -f $dir), '--watch-seconds=4') 800 $action
  $m = [regex]::Match($r.Text, 'events=(\d+) row_changes=(\d+) added=(\d+) removed=(\d+)')
  $mm = [regex]::Match($r.Text, 'rows_before=(\d+) rows_after=(\d+)')
  if (-not $m.Success -or -not $mm.Success) {
    Add-Row '外部改目录' 'FAIL' '—' ('没有 watch 汇总行；exit {0}' -f $r.Code)
    return
  }
  $events = [int]$m.Groups[1].Value
  $added = [int]$m.Groups[3].Value
  $before = [int]$mm.Groups[1].Value
  $after = [int]$mm.Groups[2].Value
  $ok = ($r.Code -eq 0 -and $events -gt 0 -and $added -ge 50 -and ($after - $before) -eq 50)
  $stat = 'events={0} added={1} 行数 {2}→{3}' -f $events, $added, $before, $after

  # UI 快照那一帧的行数：`--browse` + `--nanoui-snapshot` 打出 matched=N/N。
  $uiNote = ''
  if (-not $SkipSnapshot) {
    $png = Join-Path $Root 'snap-after-50.png'
    $snap = Invoke-Exe $Exe @('--browse', ('"{0}"' -f $dir), ('--nanoui-snapshot="{0}"' -f $png), '--nanoui-wait=2')
    $sm = [regex]::Matches($snap.Text, 'matched=(\d+)/(\d+)') | Select-Object -Last 1
    if ($sm.Success) {
      $uiRows = [int]$sm.Groups[1].Value
      $uiNote = '；UI 快照 matched={0}/{1}' -f $uiRows, $sm.Groups[2].Value
      if ($uiRows -ne $after) { $ok = $false }
    }
  }
  $note = '判据：收到事件、行数 +50' + $uiNote
  if ($ok) { Add-Row '外部改目录' 'PASS' $stat $note } else { Add-Row '外部改目录' 'FAIL' $stat $note }
}

# ---------------------------------------------------------------------------
# 7. 删除选中的文件
# ---------------------------------------------------------------------------

function Invoke-DeleteSelected {
  Write-Step '7. 删除选中的文件'
  $dir = Join-Path $Root 'watch3'
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
  New-FileSet $dir 20 'v'
  $target = Join-Path $dir 'v000010.png'
  $action = { Remove-Item -LiteralPath $target -Force }.GetNewClosure()
  $r = Invoke-ExeWhile $Exe @('--browse-watch-probe', ('"{0}"' -f $dir), '--watch-seconds=3', '--browse-select=v000010.png') 1200 $action
  # 每个字段单独取：汇总行里它们的先后顺序不固定（deleted_marked 在 selection_after 之后）。
  $markedMatch = [regex]::Match($r.Text, 'deleted_marked=(\w+)')
  $adjacentMatch = [regex]::Match($r.Text, 'adjacent=(\w+)')
  $beforeMatch = [regex]::Match($r.Text, 'rows_before=(\d+)')
  $afterMatch = [regex]::Match($r.Text, 'rows_after=(\d+)')
  if (-not $markedMatch.Success -or -not $beforeMatch.Success -or -not $afterMatch.Success) {
    Add-Row '删除选中行' 'FAIL' '—' ('没有 watch 汇总行；exit {0}' -f $r.Code)
    return
  }
  $marked = $markedMatch.Groups[1].Value -eq 'true'
  $adjacent = $adjacentMatch.Groups[1].Value -eq 'true'
  $rowsBefore = [int]$beforeMatch.Groups[1].Value
  $rowsAfter = [int]$afterMatch.Groups[1].Value
  $sel = [regex]::Match($r.Text, 'selection_after=(\S*)')
  $ok = ($r.Code -eq 0 -and $marked -and $adjacent -and $rowsAfter -eq $rowsBefore -and $sel.Success -and $sel.Groups[1].Value.Length -gt 0)
  $stat = 'deleted_marked={0} adjacent={1} rows={2}→{3} 选中={4}' -f $markedMatch.Groups[1].Value, $adjacentMatch.Groups[1].Value, $rowsBefore, $rowsAfter, $sel.Groups[1].Value
  $note = '判据：不崩、选中移到相邻行、该行标"已删除"（墓碑行保留，行数不变）'
  if ($ok) { Add-Row '删除选中行' 'PASS' $stat $note } else { Add-Row '删除选中行' 'FAIL' $stat $note }
}

# ---------------------------------------------------------------------------
# 8. 权限拒绝
# ---------------------------------------------------------------------------

function Invoke-Denied {
  Write-Step '8. 权限拒绝（文件 / 目录）'
  $dir = Join-Path $Root 'deny'
  # 上一轮可能留下了拒绝读取的 ACL：先恢复再删，否则删不掉（也不该删不掉）。
  $user = $env:USERNAME
  if (Test-Path -LiteralPath (Join-Path $dir 'secret.wav')) { $null = & icacls (Join-Path $dir 'secret.wav') /remove:d $user 2>&1 }
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $bytes = [System.Text.Encoding]::ASCII.GetBytes('otto-browse')
  [System.IO.File]::WriteAllBytes((Join-Path $dir 'ok1.wav'), $bytes)
  [System.IO.File]::WriteAllBytes((Join-Path $dir 'ok2.wav'), $bytes)
  [System.IO.File]::WriteAllBytes((Join-Path $dir 'secret.wav'), $bytes)

  $user = $env:USERNAME
  $deniedFile = $false
  $null = & icacls (Join-Path $dir 'secret.wav') /deny ('{0}:(R)' -f $user) 2>&1
  if ($LASTEXITCODE -eq 0) { $deniedFile = $true }

  $r = Invoke-Exe $Exe @('--browse-probe', ('"{0}"' -f $dir), '--preview-first=secret.wav')
  $entriesMatch = [regex]::Match($r.Text, 'entries=(\d+)')
  $unreadableMatch = [regex]::Matches($r.Text, 'unreadable=(\d+)') | Select-Object -Last 1
  $identityMatch = [regex]::Matches($r.Text, 'identity=(\w+)') | Select-Object -Last 1
  $entries = if ($entriesMatch.Success) { [int]$entriesMatch.Groups[1].Value } else { -1 }
  $unreadable = if ($unreadableMatch.Success) { [int]$unreadableMatch.Groups[1].Value } else { -1 }
  $identity = if ($identityMatch.Success) { $identityMatch.Groups[1].Value } else { '?' }

  # 目录本身没有列出权限：探针必须给出具名原因（AccessDenied / denied=true）而不是崩。
  $denyRoot = Join-Path $Root 'deny-root'
  if (Test-Path -LiteralPath $denyRoot) { Remove-Item -LiteralPath $denyRoot -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $denyRoot | Out-Null
  $null = & icacls $denyRoot /deny ('{0}:(RD)' -f $user) 2>&1
  $rootDenied = ($LASTEXITCODE -eq 0)
  $probeRoot = 'SKIP'
  $rootOk = (-not $rootDenied)
  if ($rootDenied) {
    $rr = Invoke-Exe $Exe @('--browse-probe', ('"{0}"' -f $denyRoot))
    $dm = [regex]::Match($rr.Text, 'denied=(\w+)')
    $named = $rr.Text -match 'reason=AccessDenied'
    # 目录打不开 = 入口就拒绝（exit 2 + 具名原因），或者枚举时识别成 denied=true；
    # 两条路都算"不崩、有具名答案"。
    if ($named) { $probeRoot = 'reason=AccessDenied exit=2'; $rootOk = $true }
    elseif ($dm.Success -and $dm.Groups[1].Value -eq 'true' -and $rr.Code -eq 0) { $probeRoot = 'denied=true exit=0'; $rootOk = $true }
    else { $probeRoot = ('denied={0} exit={1}' -f $dm.Groups[1].Value, $rr.Code); $rootOk = $false }
    $null = & icacls $denyRoot /remove:d $user 2>&1
    Remove-Item -LiteralPath $denyRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  $ok = ($r.Code -eq 0 -and $entries -eq 3 -and $rootOk)
  if ($deniedFile) { $ok = $ok -and ($unreadable -ge 1) -and ($identity -eq 'false') }
  $stat = '文件: entries={0} unreadable={1} identity={2}；目录: {3}' -f $entries, $unreadable, $identity, $probeRoot
  $note = '判据：不崩；打不开的文件仍在列表里并计数（ACL {0}）' -f ($(if ($deniedFile) { '已设置' } else { '设置失败→只验不崩' }))
  if ($ok) { Add-Row '权限拒绝' 'PASS' $stat $note } else { Add-Row '权限拒绝' 'FAIL' $stat $note }
}

# ---------------------------------------------------------------------------
# 附加：目录被删除（要求 5 的后半句"显示路径不可用，不崩"）
# ---------------------------------------------------------------------------

function Invoke-Vanish {
  Write-Step '附加. 目录被删除'
  $dir = Join-Path $Root 'vanishing'
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
  New-FileSet $dir 10 'x'
  $action = { Remove-Item -LiteralPath $dir -Recurse -Force }.GetNewClosure()
  $r = Invoke-ExeWhile $Exe @('--browse-watch-probe', ('"{0}"' -f $dir), '--watch-seconds=3') 1200 $action
  $m = [regex]::Match($r.Text, 'unavailable=(\w+)')
  $ok = ($r.Code -eq 0 -and $m.Success -and $m.Groups[1].Value -eq 'true')
  $stat = if ($m.Success) { 'unavailable={0} exit={1}' -f $m.Groups[1].Value, $r.Code } else { '没有 watch 汇总行' }
  $note = '判据：不崩；界面显示"路径不可用"（事件驱动，没有定时轮询）'
  if ($ok) { Add-Row '目录被删除' 'PASS' $stat $note } else { Add-Row '目录被删除' 'FAIL' $stat $note }
}

# ---------------------------------------------------------------------------
# 9. 库模式未受影响
# ---------------------------------------------------------------------------

function Invoke-LibraryMode {
  Write-Step '9. 库模式未受影响（--filter / 三套测试在 health.ps1）'
  $appDir = Join-Path $PSScriptRoot 'app'
  $library = Join-Path $appDir 'fixtures\library.json'
  if (-not (Test-Path -LiteralPath $library)) { Add-Row '库模式' 'SKIP' '—' '没有 fixtures/library.json'; return }
  $r = Invoke-Exe $Exe @('--filter=', ('"{0}"' -f $library))
  $m = [regex]::Match($r.Text, 'filter=".*" total=(\d+) matched=(\d+)')
  $ok = ($r.Code -eq 0 -and $m.Success -and [int]$m.Groups[1].Value -eq 2000 -and [int]$m.Groups[2].Value -eq 2000)
  $stat = if ($m.Success) { 'fixtures total={0} matched={1}' -f $m.Groups[1].Value, $m.Groups[2].Value } else { '没有 filter 汇总行' }
  $note = '完整闸门是 zig\health.ps1 -Quick（10 PASS）+ core/ports/app 三套测试'
  if ($ok) { Add-Row '库模式' 'PASS' $stat $note } else { Add-Row '库模式' 'FAIL' $stat $note }
}

# ---------------------------------------------------------------------------
# 10. 分页 / 每行开销 / 页大小（Stage 1）
# ---------------------------------------------------------------------------

function Get-HundredKPageProbe {
  if ($null -ne $script:hundredKPage) { return $script:hundredKPage }
  $dir = Join-Path $Root '100k'
  # `--pages=3`：首批之后最多再点 3 次「加载更多」。默认页 50000，10 万目录两次就到底。
  $script:hundredKPage = Invoke-Exe $Exe @('--browse-probe', ('"{0}"' -f $dir), '--pages=3')
  return $script:hundredKPage
}

function Invoke-Paging {
  Write-Step '10. 分页（10 万目录，--pages=3）'
  $r = Get-HundredKPageProbe
  $em = [regex]::Match($r.Text, 'entries=(\d+) truncated=(\w+)')
  $pm = [regex]::Match($r.Text, 'pages=(\d+) load_more_calls=(\d+) has_more=(\w+) mem_refused=(\w+) remaining=(\d+)')
  $peakMatch = [regex]::Match($r.Text, 'peak_mib=([0-9.]+)')
  if (-not $em.Success -or -not $pm.Success -or -not $peakMatch.Success) {
    Add-Row '分页' 'FAIL' '—' ('没有 probe 汇总行；exit {0}' -f $r.Code)
    return
  }
  $entries = [int]$em.Groups[1].Value
  $truncated = $em.Groups[2].Value -eq 'true'
  $pages = [int]$pm.Groups[1].Value
  $loadMore = [int]$pm.Groups[2].Value
  $hasMore = $pm.Groups[3].Value -eq 'true'
  $memRefused = $pm.Groups[4].Value -eq 'true'
  $remaining = [int]$pm.Groups[5].Value
  $peak = [double]$peakMatch.Groups[1].Value
  # 两条合法出路：① 真的加载了 >5 万条且 truncated=false；② 按 90 MiB 预算拒绝，
  # 并且把"还剩多少条"数出来（拒绝必须有具名理由，不许悄悄停）。
  $loadedAll = ($entries -gt 50000) -and (-not $truncated) -and (-not $hasMore)
  $refusedNamed = $memRefused -and $remaining -gt 0
  $ok = ($r.Code -eq 0 -and $peak -le 90 -and (($loadedAll -and $pages -ge 2) -or $refusedNamed))
  $stat = 'entries={0} truncated={1} pages={2}（点 {3} 次）peak={4:N2} MiB' -f $entries, $em.Groups[2].Value, $pages, $loadMore, $peak
  $note = '判据：>5 万且 truncated=false，或内存拒绝 + 剩余条数具名；峰值 ≤ 90 MiB'
  if ($ok) { Add-Row '分页' 'PASS' $stat $note } else { Add-Row '分页' 'FAIL' $stat $note }
}

function Invoke-RowCost {
  Write-Step '11. 每行实际开销（预算判断用的数）'
  $r = Get-HundredKPageProbe
  $rowMatch = [regex]::Match($r.Text, 'row_bytes=(\d+) bytes_per_row=([0-9.]+)')
  $peakMatch = [regex]::Match($r.Text, 'peak_mib=([0-9.]+)')
  if (-not $rowMatch.Success) {
    Add-Row '每行开销' 'FAIL' '—' '没有 row_bytes / bytes_per_row'
    return
  }
  $rowBytes = [int]$rowMatch.Groups[1].Value
  $perRow = [double]$rowMatch.Groups[2].Value
  $peak = if ($peakMatch.Success) { [double]$peakMatch.Groups[1].Value } else { -1 }
  # 实测值必须落在人话范围：小于 100 B/行说明没算到行存储；大于 4 KiB 说明把
  # 进程底噪算进去了。判据同时要求峰值 ≤ 90 MiB。
  $ok = ($rowBytes -gt 0 -and $perRow -gt 100 -and $perRow -lt 4096 -and $peak -le 90)
  $stat = '实测 {0:N1} B/行（当前行存储 {1:N2} MiB）；峰值 {2:N2} MiB' -f $perRow, ($rowBytes / 1MB), $peak
  $note = '判据：报告给出实测字节/行（不是猜的 1 KiB），预算判断用这个数'
  if ($ok) { Add-Row '每行开销' 'PASS' $stat $note } else { Add-Row '每行开销' 'FAIL' $stat $note }
}

function Invoke-PageSize {
  Write-Step '12. 页大小（--browse-limit=1000，1 万目录）'
  $dir = Join-Path $Root '10k'
  $r = Invoke-Exe $Exe @('--browse-probe', ('"{0}"' -f $dir), '--browse-limit=1000', '--pages=2')
  $em = [regex]::Match($r.Text, 'entries=(\d+) truncated=(\w+)')
  $pm = [regex]::Match($r.Text, 'limit=(\d+) pages=(\d+) load_more_calls=(\d+) has_more=(\w+)')
  if (-not $em.Success -or -not $pm.Success) {
    Add-Row '页大小' 'FAIL' '—' ('没有 probe 汇总行；exit {0}' -f $r.Code)
    return
  }
  $entries = [int]$em.Groups[1].Value
  $limit = [int]$pm.Groups[1].Value
  $pages = [int]$pm.Groups[2].Value
  $clicks = [int]$pm.Groups[3].Value
  $hasMore = $pm.Groups[4].Value -eq 'true'
  # 首批 1000 + 两次「加载更多」= 3000；1 万目录还有更多（不静默少显示）。
  $ok = ($r.Code -eq 0 -and $limit -eq 1000 -and $entries -eq 3000 -and $pages -eq 3 -and $clicks -eq 2 -and $hasMore)
  $stat = 'limit={0} entries={1} pages={2} clicks={3} has_more={4}' -f $limit, $entries, $pages, $clicks, $pm.Groups[4].Value
  $note = '判据：一页 1000 条，加载更多续读两页 = 3000，且仍然声明还有更多'
  if ($ok) { Add-Row '页大小' 'PASS' $stat $note } else { Add-Row '页大小' 'FAIL' $stat $note }
}

# ---------------------------------------------------------------------------
# 13. 重扫期间拷文件：最终行数不丢
# ---------------------------------------------------------------------------

function Invoke-RescanKeep {
  Write-Step '13. 重扫期间拷 50 个文件（reconcile-after-rescan）'
  $dir = Join-Path $Root 'rescan1'
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
  New-FileSet $dir 200 'w'
  # 探针自己触发重扫；重扫枚举到一半时暂停 1500ms，在这段窗口里拷 50 个 `a-` 文件
  # （名字序在游标之前，枚举器不会列它们——只有 reconcile 能把它们补进来）。
  $r = Invoke-Exe $Exe @('--browse-watch-probe', ('"{0}"' -f $dir), '--force-rescan',
    '--rescan-pause-ms=1500', '--copy-during-rescan=50', '--watch-seconds=2')
  $m = [regex]::Match($r.Text, 'browse-watch-probe: rescan paused=(\w+) copied=(\d+) rows_before=(\d+) rows_after=(\d+) disk_rows=(\d+) expected=(\d+)')
  if (-not $m.Success) {
    Add-Row '重扫不丢' 'FAIL' '—' ('没有 rescan 汇总行；exit {0}' -f $r.Code)
    return
  }
  $paused = $m.Groups[1].Value -eq 'true'
  $copied = [int]$m.Groups[2].Value
  $before = [int]$m.Groups[3].Value
  $after = [int]$m.Groups[4].Value
  $disk = [int]$m.Groups[5].Value
  $expected = [int]$m.Groups[6].Value
  $ok = ($r.Code -eq 0 -and $paused -and $copied -eq 50 -and $before -eq 200 -and
    $after -eq 250 -and $disk -eq 250 -and $expected -eq 250)
  $stat = 'paused={0} copied={1} 行数 {2}→{3}（磁盘 {4}）' -f $m.Groups[1].Value, $copied, $before, $after, $disk
  $note = '判据：重扫窗口里拷入 50 个，最终行数与磁盘一致（不丢）'
  if ($ok) { Add-Row '重扫不丢' 'PASS' $stat $note } else { Add-Row '重扫不丢' 'FAIL' $stat $note }
}

# ---------------------------------------------------------------------------
# 14. 目录消失再回来：unavailable 翻转 + 交互恢复
# ---------------------------------------------------------------------------

function Invoke-VanishReturn {
  Write-Step '14. 目录消失再回来（--vanish-then-return）'
  $dir = Join-Path $Root 'returning'
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
  New-FileSet $dir 10 'r'
  $r = Invoke-Exe $Exe @('--browse-watch-probe', ('"{0}"' -f $dir), '--vanish-then-return=1', '--watch-seconds=1')
  $m = [regex]::Match($r.Text, 'browse-watch-probe: vanish unavailable_before=(\w+) unavailable_after=(\w+) rows_after=(\d+) disk_rows=(\d+) recovered=(\w+)')
  if (-not $m.Success) {
    Add-Row '消失回来' 'FAIL' '—' ('没有 vanish 汇总行；exit {0}' -f $r.Code)
    return
  }
  $before = $m.Groups[1].Value -eq 'true'
  $after = $m.Groups[2].Value -eq 'true'
  $rows = [int]$m.Groups[3].Value
  $disk = [int]$m.Groups[4].Value
  $recovered = $m.Groups[5].Value -eq 'true'
  $ok = ($r.Code -eq 0 -and $before -and (-not $after) -and $rows -eq 10 -and $disk -eq 10 -and $recovered)
  $stat = 'unavailable {0}→{1}；行数 {2}（磁盘 {3}）' -f $m.Groups[1].Value, $m.Groups[2].Value, $rows, $disk
  $note = '判据：删除后显示不可用；目录回来 + 下一次交互后恢复（epoch+1），行数与磁盘一致'
  if ($ok) { Add-Row '消失回来' 'PASS' $stat $note } else { Add-Row '消失回来' 'FAIL' $stat $note }
}

function Invoke-MemoryRefusal {
  Write-Step '15. 内存预算拒绝（--browse-limit=200000，10 万目录）'
  $dir = Join-Path $Root '100k'
  # 页大小 20 万：第二次「加载更多」要再加 20 万行，按实测每行字节预测必然越过
  # 90 MiB。此时必须**拒绝并数清剩余**，而不是加载一半悄悄停。
  $r = Invoke-Exe $Exe @('--browse-probe', ('"{0}"' -f $dir), '--browse-limit=200000', '--pages=1')
  $em = [regex]::Match($r.Text, 'entries=(\d+) truncated=(\w+)')
  $pm = [regex]::Match($r.Text, 'pages=(\d+) load_more_calls=(\d+) has_more=(\w+) mem_refused=(\w+) remaining=(\d+)')
  $peakMatch = [regex]::Match($r.Text, 'peak_mib=([0-9.]+)')
  if (-not $em.Success -or -not $pm.Success -or -not $peakMatch.Success) {
    Add-Row '内存拒绝' 'FAIL' '—' ('没有 probe 汇总行；exit {0}' -f $r.Code)
    return
  }
  $entries = [int]$em.Groups[1].Value
  $memRefused = $pm.Groups[4].Value -eq 'true'
  $remaining = [int]$pm.Groups[5].Value
  $hasMore = $pm.Groups[3].Value -eq 'true'
  $peak = [double]$peakMatch.Groups[1].Value
  $ok = ($r.Code -eq 0 -and $entries -eq 50000 -and $memRefused -and $remaining -gt 0 -and (-not $hasMore) -and $peak -le 90)
  $stat = 'entries={0} mem_refused={1} remaining={2} peak={3:N2} MiB' -f $entries, $pm.Groups[4].Value, $remaining, $peak
  $note = '判据：按实测每行字节预测越线 → 拒绝加载并数清剩余（状态条写「已到内存上限，剩余 N 条未加载」）'
  if ($ok) { Add-Row '内存拒绝' 'PASS' $stat $note } else { Add-Row '内存拒绝' 'FAIL' $stat $note }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot 'browse_nav_accept.ps1')
. (Join-Path $PSScriptRoot 'browse_address_accept.ps1')
. (Join-Path $PSScriptRoot 'browse_robust_accept.ps1')

Write-Output 'OTTO Lite 目录浏览 Stage 0 + Stage 1 验收'
Write-Output ('exe: {0}' -f $Exe)

if (-not (Test-Path -LiteralPath $Exe)) {
  Write-Output ('致命错误：找不到 {0}（先 zig build -Drelease=true）' -f $Exe)
  exit 1
}

Initialize-Fixtures $Root ([bool]$Recreate)
# 大目录导航夹具只在本轮末尾加入；下一轮先移除，原 18 项仍看到纯 10 万文件。
$navChildren = @((Join-Path $Root '100k\nav-child'), (Join-Path $Root '100k\a-nav-child'))
foreach ($navChild in $navChildren) {
  if (Test-Path -LiteralPath $navChild) { Remove-Item -LiteralPath $navChild -Recurse -Force }
}

Invoke-FirstPage
Invoke-HundredThousand
$previewOk = Invoke-PreviewLatency
Invoke-Scroll
Invoke-ZeroWrite
Invoke-ExternalChange
Invoke-DeleteSelected
Invoke-Denied
Invoke-Vanish
Invoke-LibraryMode
Invoke-Paging
Invoke-RowCost
Invoke-PageSize
Invoke-RescanKeep
Invoke-VanishReturn
Invoke-MemoryRefusal
Invoke-NavAcceptance
Invoke-AddressAcceptance
Invoke-RobustAcceptance

# 清理 ACL 残留（deny 目录已删过；deny-root 恢复在上面做了）。
$null = $previewOk

$script:clock.Stop()
Print-Table

$failCount = @($script:rows | Where-Object { $_.Result -eq 'FAIL' }).Count
if ($failCount -gt 0) { exit 1 }
exit 0
