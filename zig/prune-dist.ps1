# 给 zig\dist 定一条保留策略，并把"删"这件事做成默认不删。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\prune-dist.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\prune-dist.ps1 -Apply
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\prune-dist.ps1 -Apply -WhatIf
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\prune-dist.ps1 -KeepVersion 0.29.0
#
# 保留策略（五条来源取并集）：
#
#   1. 最新的 N 个版本（默认 2）——"上一版还能装、还能回退"是发布的基本要求；
#   2. 当前 build.zig.zon 里的版本——它和源码对得上，是唯一能重建的那一版；
#   3. verify 用过的版本——写在 zig\dist\.verify-used 里（一行一个版本，# 开头是注释）。
#      为什么是标记文件：verify-distribution.ps1 **刻意不读 dist**（它用 zig-out 里的
#      exe 模拟三种形态，从不运行安装包），所以"最近用过哪些 dist 产物"这件事今天只能
#      由跑验收的人显式记下来。标记文件不存在就是"没有额外要保的"，不是错误；
#      fresh-user.ps1 每次跑完会把用过的版本打在自己的报告里，抄进来即可。
#   4. -KeepVersion 显式点名——临时要保某一版时用它，不必改脚本；
#   5. **测试硬编码引用的版本**——zig\app\src 里写着 zig\dist\otto-lite-<x.y.z>-setup.exe
#      的地方，那个版本不能删：删了对应用例会返回 SkipZigTest，而 health.ps1 把 skip
#      当失败。**"测试变少"比"测试变红"更难查**，所以这条是自动的：扫源码，不靠人记得。
#      （0.31.0 那次清理实测过：删完 app 315/320；0.32.0 起更新检查/下载的测试改用自造
#      夹具（app\src\update_fixture.zig），这里现在扫不到东西。扫描保留，防复发。）

#
# 删除的对象只有这四种文件：otto-lite-<x.y.z>-portable.zip / -setup.exe / 及各自的 .sig。
# 别的东西（staging 目录、标记文件、README）一律不碰，并且会在报告里列出来。
#
# 默认只报告、不动手：先看清单再 -Apply。这是有意的——删掉的分发物是**不可重建的**
# （私钥签过的旧版本，重建出来的字节和签名都不一样）。
#
# 本文件是 UTF-8 **带 BOM**：Windows PowerShell 5.1 把无 BOM 的 .ps1 当 ANSI 读，中文会乱。

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$DistDir = '',
  [string]$ZonFile = '',
  [int]$KeepNewest = 2,
  [string[]]$KeepVersion = @(),
  # 默认 zig\dist\.verify-used；给空字符串表示"没有这个来源"。
  [string]$UsedFile = '',
  [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$script:root = $PSScriptRoot
if (-not $DistDir) { $DistDir = Join-Path $script:root 'dist' }
$script:distDir = [IO.Path]::GetFullPath($DistDir)
if (-not $ZonFile) { $ZonFile = Join-Path $script:root 'app\build.zig.zon' }
if (-not $UsedFile) { $UsedFile = Join-Path $script:distDir '.verify-used' }
if ($KeepNewest -lt 1) { throw ('-KeepNewest 至少是 1（收到 {0}）' -f $KeepNewest) }

if (-not (Test-Path -LiteralPath $script:distDir -PathType Container)) {
  throw ('找不到 dist 目录：{0}' -f $script:distDir)
}

# 产物命名是唯一判据：不匹配的一律当"不认识的文件"，保留并列出来。
$artifactPattern = '^otto-lite-(\d+\.\d+\.\d+)-(portable\.zip|setup\.exe)(\.sig)?$'

function Write-Head([string]$Text) {
  Write-Host ''
  Write-Host $Text
}

function Get-VersionKey([string]$Text) {
  try { return [version]$Text } catch { return $null }
}

# ---------------------------------------------------------------------------
# 1. 清点：按版本分组
# ---------------------------------------------------------------------------

$files = @(Get-ChildItem -LiteralPath $script:distDir -File -Force | Sort-Object Name)
$versions = @{}          # "0.31.0" -> 该版本的文件数组
$unknown = @()           # 不认识的文件
foreach ($file in $files) {
  $m = [regex]::Match($file.Name, $artifactPattern)
  if (-not $m.Success) { $unknown += $file; continue }
  $key = $m.Groups[1].Value
  if (-not $versions.ContainsKey($key)) { $versions[$key] = @() }
  $versions[$key] = @($versions[$key]) + $file
}

$ordered = @($versions.Keys | Sort-Object { Get-VersionKey $_ } -Descending)

# ---------------------------------------------------------------------------
# 2. 当前版本：build.zig.zon 是唯一来源（和 package.ps1 读的是同一行）
# ---------------------------------------------------------------------------

$currentVersion = ''
if (Test-Path -LiteralPath $ZonFile -PathType Leaf) {
  $zonText = Get-Content -LiteralPath $ZonFile -Raw
  $zm = [regex]::Match($zonText, '\.version\s*=\s*"([^"]+)"')
  if ($zm.Success) { $currentVersion = $zm.Groups[1].Value }
}
if (-not $currentVersion) {
  Write-Warning ('读不到 build.zig.zon 的 .version（{0}）：策略里少一条"当前版本"来源' -f $ZonFile)
}

# ---------------------------------------------------------------------------
# 3. verify 用过的版本（标记文件，可缺）
# ---------------------------------------------------------------------------

$usedVersions = @()
if ($UsedFile -and (Test-Path -LiteralPath $UsedFile -PathType Leaf)) {
  foreach ($line in @(Get-Content -LiteralPath $UsedFile)) {
    $trimmed = [string]$line
    $trimmed = $trimmed.Trim()
    if ($trimmed.Length -eq 0) { continue }
    if ($trimmed.StartsWith('#')) { continue }
    if ($trimmed -notmatch '^\d+\.\d+\.\d+$') {
      Write-Warning ('忽略 .verify-used 里不认识的一行：{0}' -f $trimmed)
      continue
    }
    if ($usedVersions -notcontains $trimmed) { $usedVersions += $trimmed }
  }
}

# ---------------------------------------------------------------------------
# 3b. 测试硬编码引用的版本（扫 zig\app\src）
#
# 删掉被硬编码引用的版本不会让测试变红，而是让测试**变少**（SkipZigTest）；跳过比失败
# 更难查，所以这条不能靠人记得。0.32.0 起 update_* 的测试改成了自造夹具，这里应变空。
# ---------------------------------------------------------------------------

$fixtureVersions = @()
$fixtureFiles = @()
$appSrc = Join-Path $script:root 'app\src'
if (Test-Path -LiteralPath $appSrc -PathType Container) {
  $sourceFiles = @(Get-ChildItem -LiteralPath $appSrc -Recurse -File -Filter '*.zig' -ErrorAction SilentlyContinue)
  foreach ($item in $sourceFiles) {
    $text = [IO.File]::ReadAllText($item.FullName, [Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($text, 'zig[\\/]+dist[\\/]+otto-lite-(\d+\.\d+\.\d+)-')) {
      $v = $m.Groups[1].Value
      if ($fixtureVersions -notcontains $v) { $fixtureVersions += $v }
      if ($fixtureFiles -notcontains $item.Name) { $fixtureFiles += $item.Name }
    }
  }
}

# ---------------------------------------------------------------------------
# 4. 决定保留谁，并记下理由
# ---------------------------------------------------------------------------

$keepReason = @{}
if ($ordered.Count -gt 0) {
  for ($i = 0; $i -lt [Math]::Min($KeepNewest, $ordered.Count); $i++) {
    $keepReason[$ordered[$i]] = ('最新 {0}' -f $KeepNewest)
  }
}
if ($currentVersion) {
  if ($keepReason.ContainsKey($currentVersion)) {
    $keepReason[$currentVersion] = $keepReason[$currentVersion] + ' / 当前版本（build.zig.zon）'
  } else {
    $keepReason[$currentVersion] = '当前版本（build.zig.zon）'
  }
}
foreach ($version in $usedVersions) {
  if ($keepReason.ContainsKey($version)) {
    $keepReason[$version] = $keepReason[$version] + ' / verify 用过'
  } else {
    $keepReason[$version] = 'verify 用过（.verify-used）'
  }
}
foreach ($version in $fixtureVersions) {
  if (-not $versions.ContainsKey($version)) {
    Write-Warning ('测试夹具引用了 {0}，但 dist 里没有这一版：引用它的用例会变成 SKIP' -f $version)
    continue
  }
  if ($keepReason.ContainsKey($version)) {
    $keepReason[$version] = $keepReason[$version] + ' / 测试夹具'
  } else {
    $keepReason[$version] = '测试夹具（zig\app\src 硬编码）'
  }
}
foreach ($version in @($KeepVersion)) {
  if (-not $version) { continue }
  if ($versions.ContainsKey($version)) {
    if ($keepReason.ContainsKey($version)) {
      $keepReason[$version] = $keepReason[$version] + ' / -KeepVersion'
    } else {
      $keepReason[$version] = '-KeepVersion'
    }
  } else {
    Write-Warning ('-KeepVersion {0}：dist 里没有这个版本' -f $version)
  }
}

$keep = @($keepReason.Keys | Sort-Object { Get-VersionKey $_ } -Descending)
$drop = @($ordered | Where-Object { -not $keepReason.ContainsKey($_) })

# ---------------------------------------------------------------------------
# 5. 报告
# ---------------------------------------------------------------------------

$distBytes = 0
foreach ($file in $files) { $distBytes += $file.Length }

Write-Host 'OTTO Lite 分发物清理'
Write-Host ('dist：{0}' -f $script:distDir)
Write-Host ('版本：{0} 个（{1} … {2}）；文件：{3} 个；合计 {4:N1} MB' -f
  $ordered.Count, $ordered[$ordered.Count - 1], $ordered[0], $files.Count, ($distBytes / 1MB))
if ($currentVersion) {
  Write-Host ('当前版本（app\build.zig.zon）：{0}' -f $currentVersion)
} else {
  Write-Host '当前版本：（未知）'
}
if ($UsedFile -and (Test-Path -LiteralPath $UsedFile -PathType Leaf)) {
  Write-Host ('verify 标记：{0} → {1}' -f $UsedFile, (($usedVersions -join '、')))
} else {
  Write-Host ('verify 标记：没有 {0}（verify-distribution 目前不读 dist 产物，默认没有额外要保的版本）' -f $UsedFile)
}
if ($fixtureVersions.Count -gt 0) {
  Write-Host ('测试夹具：{0}（被 {1} 硬编码引用；删了会让引用它的用例变成 SKIP）' -f
    ($fixtureVersions -join '、'), ($fixtureFiles -join '、'))
} else {
  Write-Host '测试夹具：zig\app\src 里没有引用 dist 的版本'
}

Write-Head ('== 保留 {0} 个版本 ==' -f $keep.Count)
foreach ($version in $keep) {
  $size = 0
  foreach ($file in @($versions[$version])) { $size += $file.Length }
  Write-Host ('  {0,-8} {1,7:N1} MB  {2}' -f $version, ($size / 1MB), $keepReason[$version])
}

$dropFiles = @()
foreach ($version in $drop) { $dropFiles += @($versions[$version]) }
$dropBytes = 0
foreach ($file in $dropFiles) { $dropBytes += $file.Length }

Write-Head ('== 删除 {0} 个版本 / {1} 个文件 / {2:N1} MB ==' -f $drop.Count, $dropFiles.Count, ($dropBytes / 1MB))
if ($drop.Count -eq 0) {
  Write-Host '  没有要删的。'
} else {
  Write-Host ('  版本：{0}' -f (($drop | Sort-Object { Get-VersionKey $_ }) -join '、'))
  Write-Host '  路径清单（逐条核对：全部在 dist 下、全部匹配产物命名）：'
  $outOfPlace = @()
  foreach ($file in $dropFiles) {
    $full = [IO.Path]::GetFullPath($file.FullName)
    $inside = $full.StartsWith($script:distDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    $matchesPattern = [regex]::IsMatch($file.Name, $artifactPattern)
    if (-not ($inside -and $matchesPattern)) { $outOfPlace += $full }
    Write-Host ('    {0,10:N0} B  {1}{2}' -f $file.Length, $full, $(if ($inside -and $matchesPattern) { '' } else { '   ← 越界，拒绝删除' }))
  }
  Write-Host ('  安全检查：{0} 个路径越界' -f $outOfPlace.Count)
  if ($outOfPlace.Count -gt 0) {
    throw ('有 {0} 个待删路径不在 dist 下或命名不符，已中止（一个文件都没删）' -f $outOfPlace.Count)
  }
}

if ($unknown.Count -gt 0) {
  Write-Head ('== 不认识的文件：{0} 个（保留，不碰）==' -f $unknown.Count)
  foreach ($file in $unknown) { Write-Host ('    {0,12:N0} B  {1}' -f $file.Length, $file.Name) }
}

# ---------------------------------------------------------------------------
# 6. 动手（默认不动）
# ---------------------------------------------------------------------------

$deleted = @()
$freedBytes = 0
if (-not $Apply) {
  Write-Head '== 结果 =='
  Write-Host '  预演（没有删除任何文件）。加 -Apply 才会真删。'
  if ($dropFiles.Count -gt 0) {
    Write-Host ('  将要删除：{0} 个文件，释放 {1:N1} MB；保留 {2} 个文件，{3:N1} MB' -f
      $dropFiles.Count, ($dropBytes / 1MB), ($files.Count - $dropFiles.Count), (($distBytes - $dropBytes) / 1MB))
  }
  exit 0
}

# -Apply 与 PowerShell 的 -WhatIf 撞在一起时，ShouldProcess 全部返回 false：
# 那是"预演"，不是"清理失败"，所以要在核对之前就收工（否则会误报 dist 对不上）。
if ($WhatIfPreference) {
  Write-Head '== 结果 =='
  Write-Host '  -WhatIf（PowerShell 的预演）：没有删除任何文件。'
  Write-Host ('  将要删除：{0} 个文件，释放 {1:N1} MB' -f $dropFiles.Count, ($dropBytes / 1MB))
  exit 0
}

Write-Head '== 执行删除 =='
foreach ($file in $dropFiles) {
  if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove-Item')) {
    $size = $file.Length
    Remove-Item -LiteralPath $file.FullName -Force
    if (Test-Path -LiteralPath $file.FullName) {
      throw ('删不掉：{0}' -f $file.FullName)
    }
    $deleted += $file.FullName
    $freedBytes += $size
  }
}

$after = @(Get-ChildItem -LiteralPath $script:distDir -File -Force | Sort-Object Name)
$afterBytes = 0
foreach ($file in $after) { $afterBytes += $file.Length }

Write-Head '== 结果 =='
Write-Host ('  删除：{0} 个文件，释放 {1:N1} MB' -f $deleted.Count, ($freedBytes / 1MB))
Write-Host ('  保留：{0} 个版本 / {1} 个文件 / {2:N1} MB' -f $keep.Count, $after.Count, ($afterBytes / 1MB))
foreach ($version in $keep) {
  Write-Host ('    {0,-8} {1}' -f $version, (($versions[$version] | ForEach-Object { $_.Name }) -join '  '))
}
if ($unknown.Count -gt 0) {
  Write-Host ('  另有 {0} 个不认识的文件（未碰）' -f $unknown.Count)
}

# 删完再核对一次：留着的东西必须正好是 keep 集合 + unknown 集合。
$expected = @()
foreach ($version in $keep) { $expected += @($versions[$version] | ForEach-Object { $_.Name }) }
$expected += @($unknown | ForEach-Object { $_.Name })
$actual = @($after | ForEach-Object { $_.Name })
$diff = @(Compare-Object -ReferenceObject @($expected | Sort-Object) -DifferenceObject @($actual | Sort-Object))
if ($diff.Count -gt 0) {
  Write-Host '  [FAIL] 清理后的 dist 和保留清单对不上：' -ForegroundColor Red
  foreach ($row in $diff) { Write-Host ('         {0} {1}' -f $row.SideIndicator, $row.InputObject) }
  exit 1
}
$keptFileCount = $expected.Count - $unknown.Count
Write-Host ('  核对：dist 里正好剩 {0} 个文件（保留 {1} 个 + 不认识 {2} 个）' -f $actual.Count, $keptFileCount, $unknown.Count)
exit 0
