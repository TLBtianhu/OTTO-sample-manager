# 全新用户测试：一个人第一次拿到 OTTO Lite，从"下载"到"卸载"，全程在临时目录里。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\fresh-user.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\fresh-user.ps1 -KeepTemp
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\fresh-user.ps1 -Version 0.31.0
#
# 它模拟的不是"开发者顺手点一下"，而是一台从没见过这个项目的机器上的九步：
#
#   1. 造全新目录        downloads / program / appdata / localappdata（都在 %TEMP%\otto-fresh-*）
#   2. "下载"并验签      从 zig\dist 拷 setup.exe 到 downloads，用 zig\keys 的公钥验 minisign
#   3. 静默安装          NSIS /S + /D=（不带引号、放最后、路径不含空格）
#   4. 首次启动          --version 必须说 (installed) 且退出码 0
#   5. 首次真实启动      隐藏窗口的设置面板 → %APPDATA%\OTTO 被创建（settings.json 等）
#   6. 导入素材          --import（显式落盘）与 --import-into（按形态落盘）都要出 library.otto
#   7. 静默卸载          程序消失；%APPDATA%\OTTO 逐个文件、逐个字节保留
#   8. 装另一个版本      旧版本装上后，同一份用户数据照旧被沿用
#   9. 编译产物零污染    zig-out\bin 全程零变化（三个文件的名字 / 大小 / 哈希）
#
# 为什么这件事必须是一条脚本，而不是一次手动验收：
#
#   手动验收只证明"这一次、这台机器、这个目录"能用。它没有可重跑的成本下限，也没有
#   失败时的定位信息；更要紧的是，它无法证明"没碰真实用户目录"——手动验收最多是
#   "我记得我没装到 Program Files"。这条脚本把"全新用户"做成一个**可重复的**声明：
#   每次跑都从一个空目录开始，每次都断言 %APPDATA% / Program Files / zig-out 里的东西
#   没被动过。一条会失败的断言，胜过一段"我验过了"的说明。
#
# 硬约束（都写成了代码，而不是注释里的愿望）：
#
#   * 不碰真实的 %APPDATA% / %LOCALAPPDATA% / Program Files：每个子进程都显式带
#     APPDATA / LOCALAPPDATA / TEMP / TMP 覆盖（ProcessStartInfo.EnvironmentVariables），
#     父进程的环境变量一次都不改；
#   * 不弹窗：所有子进程 UseShellExecute=$false + CreateNoWindow=$true + 重定向两个流
#     （CONVENTIONS 第 2 条）；会建窗口的那一步走 --nanoui-snapshot（隐藏 HWND）；
#   * 退出前不留进程、不留临时目录（finally 里做，失败也做）；
#   * 失败即 exit 1：任何一条断言红了，整个脚本红。
#
# 安装为什么要 __COMPAT_LAYER：
#
#   installer.nsi 是 RequestExecutionLevel admin（它要写 HKLM 与全用户快捷方式）。
#   从非提权会话用 CreateProcess 起它，Windows 直接返回 740（要求提升），**不会**弹
#   UAC——CreateProcess 从不提示，只有 ShellExecute 会。脚本据此分两条路：
#     * 提权会话：NSIS 原样跑，注册表 + 快捷方式一起断言（安装后存在、卸载后消失）；
#     * 非提权会话：只给安装/卸载这两个 NSIS 进程加 __COMPAT_LAYER=RunAsInvoker，让清单里的 administrator
#       降级为"当前用户"运行。程序文件照常装进临时 program\（这是本步要验的），
#       两条需要管理员的写入（HKLM、$DESKTOP）被 /S 静默跳过。**这不是泄漏**：
#       本机真实 Program Files 与注册表一个字节都不会被写。
#
# 本文件是 UTF-8 **带 BOM**：Windows PowerShell 5.1 把无 BOM 的 .ps1 当 ANSI 读，
# 中文会被读坏（`click:设置` 这类参数会变成乱码，点不到按钮）。

[CmdletBinding()]
param(
  [string]$DistDir = '',
  [string]$Samples = 'C:\src\otto-testkit\samples',
  # 默认取 dist 里最新的 setup.exe；显式给了就必须存在。
  [string]$Version = '',
  # 第 8 步要装的"另一个版本"；默认取比 $Version 小的最新一个。
  [string]$OldVersion = '',
  # 调试用：留下临时目录（路径会打在报告里）。默认删干净。
  [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:repoRoot = Split-Path $PSScriptRoot -Parent
$script:zigDir = $PSScriptRoot
if (-not $DistDir) { $DistDir = Join-Path $PSScriptRoot 'dist' }
$script:distDir = [IO.Path]::GetFullPath($DistDir)
$script:samplesDir = [IO.Path]::GetFullPath($Samples)
$script:publicKey = Join-Path $PSScriptRoot 'keys\otto-lite.key.pub'
$script:verifyJs = Join-Path $PSScriptRoot 'tools\verify-minisign.js'
# 编译产物：本脚本只*看*它，不构建、不写。第 9 步断言它零变化。
$script:zigOutBin = Join-Path $PSScriptRoot 'app\zig-out\bin'

$script:checks = New-Object System.Collections.ArrayList
$script:currentStep = 0
$script:stepTitles = @{}
$script:stepTotal = @{}
$script:stepFailed = @{}
$script:stepSkipped = @{}
$script:clock = [System.Diagnostics.Stopwatch]::StartNew()

# 全程不写真实用户目录：这三个值只进子进程的环境块。
$script:realAppData = $env:APPDATA
$script:realTemp = $env:TEMP
$script:realOtto = if ($env:APPDATA) { Join-Path $env:APPDATA 'OTTO' } else { '' }
$script:programFiles = $env:ProgramFiles
$script:programFilesX86 = ${env:ProgramFiles(x86)}

$script:elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

# 环境变量快照：父进程一次都不改，收尾时按快照恢复**并核对**（改了也能退回去）。
$script:envBefore = @{}
foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP')) {
  $script:envBefore[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$script:tempRoot = ''
$script:cleanup = New-Object psobject -Property @{
  TempRemoved = $false
  FreedBytes = 0
  LeftoverProcesses = @()
  TempNewEntries = @()
  EnvRestored = $false
  RealOttoUnchanged = $true
  Error = ''
}

# ---------------------------------------------------------------------------
# 输出与断言
# ---------------------------------------------------------------------------

function Write-Head([string]$Text) {
  Write-Host ''
  Write-Host $Text
}

# CJK 占两个控制台单元格：只按字符数补空格，中文列会歪。
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

function Format-Cells {
  param([string[]]$Cells, [int[]]$Widths)
  $parts = @()
  for ($i = 0; $i -lt $Cells.Count; $i++) {
    $pad = $Widths[$i] - (Get-DisplayWidth $Cells[$i])
    if ($pad -lt 0) { $pad = 0 }
    $parts += ($Cells[$i] + (' ' * $pad))
  }
  return (($parts -join '  ').TrimEnd())
}

function Start-Step([int]$Number, [string]$Title) {
  $script:currentStep = $Number
  $script:stepTitles[$Number] = $Title
  $script:stepTotal[$Number] = 0
  $script:stepFailed[$Number] = 0
  $script:stepSkipped[$Number] = 0
  if ($Number -eq 0) {
    Write-Head ('── 前置条件：不满足就没法开始 ──')
  } else {
    Write-Head ('── 步骤 {0}/9：{1} ──' -f $Number, $Title)
  }
}

# 一条断言。Detail 是"关键数字"：路径、大小、退出码、哈希前 12 位。
function Add-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = ''
  )
  $step = $script:currentStep
  $script:stepTotal[$step] = $script:stepTotal[$step] + 1
  if (-not $Ok) { $script:stepFailed[$step] = $script:stepFailed[$step] + 1 }
  $null = $script:checks.Add((New-Object psobject -Property @{
    Step = $step
    Name = $Name
    Ok = $Ok
    Skip = $false
  }))
  $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
  $line = '  [{0}] {1}' -f $tag, $Name
  if ($Detail) { $line += '   ' + $Detail }
  if ($Ok) { Write-Host $line } else { Write-Host $line -ForegroundColor Red }
}

# [SKIP] 与 [PASS] 分开：跳过不是通过，也不计入失败（例如没有更旧的 dist）。
function Add-Skip([string]$Name, [string]$Why) {
  $step = $script:currentStep
  $script:stepTotal[$step] = $script:stepTotal[$step] + 1
  $script:stepSkipped[$step] = $script:stepSkipped[$step] + 1
  $null = $script:checks.Add((New-Object psobject -Property @{
    Step = $step
    Name = $Name
    Ok = $true
    Skip = $true
  }))
  Write-Host ('  [SKIP] {0}   {1}' -f $Name, $Why)
}

# 纯信息行（不参与判定）：例如"旧版本能不能读新格式"——0.x 不承诺向下兼容。
function Write-Info([string]$Text) {
  Write-Host ('  [INFO] ' + $Text)
}

function Complete-Step {
  $step = $script:currentStep
  $total = $script:stepTotal[$step]
  $failed = $script:stepFailed[$step]
  $skipped = $script:stepSkipped[$step]
  $suffix = ''
  if ($skipped -gt 0) { $suffix = '，{0} 项 SKIP' -f $skipped }
  if ($failed -eq 0) {
    Write-Host ('  → 步骤 {0} PASS（{1} 项断言{2}）' -f $step, ($total - $skipped), $suffix) -ForegroundColor Green
  } else {
    Write-Host ('  → 步骤 {0} FAIL（{1}/{2} 项失败{3}）' -f $step, $failed, $total, $suffix) -ForegroundColor Red
  }
}

function Write-FailureTail($Lines, [int]$Count = 8) {
  $tail = @($Lines | Select-Object -Last $Count)
  if ($tail.Count -eq 0) { return }
  Write-Host ('  | （末 {0} 行输出）' -f $tail.Count)
  foreach ($line in $tail) { Write-Host ('  | ' + $line) }
}

# ---------------------------------------------------------------------------
# 文件与进程
# ---------------------------------------------------------------------------

function Get-FileSha([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Get-TreeSize([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  $sum = 0
  foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
    $sum += $item.Length
  }
  return $sum
}

# 目录快照：相对路径 + 大小 + SHA-256。卸载前后的"逐个文件比对"就靠它。
function Get-TreeSnapshot([string]$Path) {
  $rows = @()
  if (-not (Test-Path -LiteralPath $Path)) { return $rows }
  foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
    $rel = $item.FullName.Substring($Path.Length).TrimStart('\')
    $rows += (New-Object psobject -Property @{
      Rel = $rel
      Length = $item.Length
      Sha = (Get-FileSha $item.FullName)
    })
  }
  return $rows
}

# 轻量快照（相对路径 + 大小，不读内容）：用来核对**真实** %APPDATA%\OTTO。
# 不哈希是故意的：机器上如果正好有一个 OTTO 在跑，它会重写自己的 settings.json，
# 哈希会让这条守卫随机变红；而"我们写进去一个新文件"仍然会被名字/大小抓住。
function Get-TreeLightSnapshot([string]$Path) {
  $rows = @()
  if (-not (Test-Path -LiteralPath $Path)) { return $rows }
  foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
    $rel = $item.FullName.Substring($Path.Length).TrimStart('\')
    $rows += [string]::Format('{0}|{1}', $rel, $item.Length)
  }
  return $rows
}

# 两份快照逐条比对：新增 / 消失 / 内容变了，三类都要看得见。
function Compare-TreeSnapshot($Before, $After) {
  $beforeMap = @{}
  foreach ($row in @($Before)) { $beforeMap[$row.Rel] = $row }
  $afterMap = @{}
  foreach ($row in @($After)) { $afterMap[$row.Rel] = $row }
  $added = @()
  $removed = @()
  $changed = @()
  foreach ($key in @($beforeMap.Keys)) {
    if (-not $afterMap.ContainsKey($key)) { $removed += $key; continue }
    if ($beforeMap[$key].Sha -ne $afterMap[$key].Sha) { $changed += $key }
  }
  foreach ($key in @($afterMap.Keys)) {
    if (-not $beforeMap.ContainsKey($key)) { $added += $key }
  }
  return (New-Object psobject -Property @{
    Ok = (($added.Count -eq 0) -and ($removed.Count -eq 0) -and ($changed.Count -eq 0))
    Added = $added
    Removed = $removed
    Changed = $changed
  })
}

# 进程一律这么起：没有窗口、两个流都读走、命令行先回显（CONVENTIONS 第 2 / 5 条）。
function Invoke-Native {
  param(
    [string]$ExePath,
    [string]$ExeArguments,
    [string]$WorkDir = '',
    [hashtable]$EnvMap = $null,
    [int]$TimeoutSeconds = 180
  )
  Write-Host ('  $ "{0}" {1}' -f $ExePath, $ExeArguments)
  if (-not (Test-Path -LiteralPath $ExePath)) {
    throw ('找不到可执行文件：{0}' -f $ExePath)
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ExePath
  $psi.Arguments = $ExeArguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
  if ($null -ne $EnvMap) {
    foreach ($key in @($EnvMap.Keys)) { $psi.EnvironmentVariables[[string]$key] = [string]$EnvMap[$key] }
  }

  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $proc = [System.Diagnostics.Process]::Start($psi)
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
  if (-not $exited) {
    try { $proc.Kill() } catch { }
    $watch.Stop()
    throw ('子进程超时（{0} s 未退出）：{1}' -f $TimeoutSeconds, $ExePath)
  }
  $outText = [string]$outTask.Result
  $errText = [string]$errTask.Result
  $code = $proc.ExitCode
  $proc.Dispose()
  $watch.Stop()

  $lines = @()
  foreach ($chunk in @($outText, $errText)) {
    foreach ($line in ($chunk -split "`r?`n")) {
      if ($line.Trim().Length -gt 0) { $lines += [string]$line }
    }
  }
  return (New-Object psobject -Property @{
    Code = $code
    Out = $outText
    Err = $errText
    Lines = [string[]]$lines
    Text = [string]::Join("`n", [string[]]$lines)
    Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
  })
}

# 子进程统一的环境块：把 %APPDATA% / %LOCALAPPDATA% / %TEMP% 指到临时树里。
# 每一个子进程都带它——这是"绝不写真实用户目录"的实现方式，而不是靠自觉。
function Get-ChildEnv {
  $map = @{}
  $map['APPDATA'] = $script:fakeAppData
  $map['LOCALAPPDATA'] = $script:fakeLocalAppData
  $map['TEMP'] = $script:fakeTemp
  $map['TMP'] = $script:fakeTemp
  return $map
}

# 只给 NSIS 的进程（setup.exe / Uninstall.exe）加兼容层。
# 见文件头：它们的清单写着 requireAdministrator，非提权会话里 CreateProcess 会返回 740，
# 兼容层把这一级降成"当前用户"（不会弹 UAC，也没有别的降级办法）。
# 应用本身与 node 都不加——它们本来就按调用者的权限跑，加一层只会让人怀疑"是不是靠它才跑通"。
function Get-InstallerEnv {
  $map = Get-ChildEnv
  if (-not $script:elevated) { $map['__COMPAT_LAYER'] = 'RunAsInvoker' }
  return $map
}

# 当前树里还活着的进程（按可执行文件路径判断，不用 Get-Process 的 .Path——
# 它对受保护进程会抛访问被拒，把整次清理带崩）。
function Get-ProcessUnder {
  param([string]$Root)
  $found = @()
  try {
    foreach ($proc in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
      $path = $proc.ExecutablePath
      if (-not $path) { continue }
      if ($path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        $found += (New-Object psobject -Property @{ Id = [int]$proc.ProcessId; Name = [string]$proc.Name; Path = [string]$path })
      }
    }
  } catch {
    $found += (New-Object psobject -Property @{ Id = -1; Name = '<CIM 查询失败>'; Path = $_.Exception.Message })
  }
  return $found
}

# 等一个路径消失（NSIS 卸载器会把自己复制到 %TEMP% 再跑，父进程先返回，
# 所以"Uninstall.exe /S 退出"不等于"卸载做完了"）。
function Wait-PathGone {
  param([string]$Path, [int]$TimeoutSeconds = 60)
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    if (-not (Test-Path -LiteralPath $Path)) {
      $watch.Stop()
      return (New-Object psobject -Property @{ Gone = $true; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2) })
    }
    Start-Sleep -Milliseconds 100
  }
  $watch.Stop()
  return (New-Object psobject -Property @{ Gone = $false; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2) })
}

function Wait-NoProcessUnder {
  param([string]$Root, [int]$TimeoutSeconds = 20)
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $last = @()
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    $last = @(Get-ProcessUnder -Root $Root)
    if ($last.Count -eq 0) {
      $watch.Stop()
      return (New-Object psobject -Property @{ Clear = $true; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2); Left = @() })
    }
    Start-Sleep -Milliseconds 100
  }
  $watch.Stop()
  return (New-Object psobject -Property @{ Clear = $false; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2); Left = $last })
}

# ---------------------------------------------------------------------------
# 版本与产物
# ---------------------------------------------------------------------------

function Get-DistVersions {
  $map = @{}
  foreach ($item in @(Get-ChildItem -LiteralPath $script:distDir -File -Filter 'otto-lite-*-setup.exe' -ErrorAction SilentlyContinue)) {
    $m = [regex]::Match($item.Name, '^otto-lite-(\d+\.\d+\.\d+)-setup\.exe$')
    if (-not $m.Success) { continue }
    $map[$m.Groups[1].Value] = [version]$m.Groups[1].Value
  }
  # [version] 排序：0.9.0 < 0.10.0（字符串排序会反着来，这正是要防的）。
  return @($map.Keys | Sort-Object { $map[$_] } -Descending)
}

function Get-SetupPath([string]$TargetVersion) {
  return (Join-Path $script:distDir ('otto-lite-{0}-setup.exe' -f $TargetVersion))
}

# ---------------------------------------------------------------------------
# 安装 / 卸载
# ---------------------------------------------------------------------------

function Install-Package {
  param(
    [string]$SetupPath,
    [string]$Target,
    [string]$Label
  )
  # /D= 是 NSIS 的最后一个参数、不带引号、路径里不能有空格——三条都是 NSIS 的硬规则：
  # 带引号会被当成路径的一部分，放在前面会被别的参数吃掉。
  $arguments = '/S /D=' + $Target
  Write-Host ('  [{0}] 参数：/S + /D=（不带引号、放最后；路径不含空格）' -f $Label)
  return (Invoke-Native -ExePath $SetupPath -ExeArguments $arguments -EnvMap (Get-InstallerEnv) -TimeoutSeconds 180)
}

function Uninstall-Package {
  param([string]$ProgramDir)
  $uninstaller = Join-Path $ProgramDir 'Uninstall.exe'
  $result = Invoke-Native -ExePath $uninstaller -ExeArguments '/S' -EnvMap (Get-InstallerEnv) -TimeoutSeconds 180
  $gone = Wait-PathGone -Path $ProgramDir -TimeoutSeconds 60
  $idle = Wait-NoProcessUnder -Root $script:tempRoot -TimeoutSeconds 20
  return (New-Object psobject -Property @{
    Code = $result.Code
    ExitSeconds = $result.Seconds
    Gone = $gone.Gone
    GoneSeconds = $gone.Seconds
    Processes = $idle
  })
}

# ---------------------------------------------------------------------------
# 验签
# ---------------------------------------------------------------------------

function Test-ArtifactSignature {
  param(
    [string]$SignaturePath,
    [string]$ArtifactPath
  )
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $node) { throw '找不到 node（verify-minisign.js 需要 Node.js）' }
  $arguments = '"{0}" "{1}" "{2}" "{3}"' -f $script:verifyJs, $script:publicKey, $SignaturePath, $ArtifactPath
  return (Invoke-Native -ExePath $node.Source -ExeArguments $arguments -TimeoutSeconds 120)
}

# 设置面板：点"设置"→ 把不透明度滑到 60%（255*0.6=153）→ 点"关闭"。
# 面板布局是固定的（和 verify-distribution.ps1 / opacity.ps1 用的同一条）。
$script:panelScript = 'click:设置;at:218,196;click:关闭'

# ---------------------------------------------------------------------------
# 设置文件断言（五个字段 + opacity=153）
# ---------------------------------------------------------------------------

function Test-SettingsFile {
  param([string]$Path, [int]$Opacity = 153)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return (New-Object psobject -Property @{ Ok = $false; Detail = ('缺少 {0}' -f $Path) })
  }
  try {
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $obj = $raw | ConvertFrom-Json
  } catch {
    return (New-Object psobject -Property @{ Ok = $false; Detail = ('JSON 无效：{0}' -f $_.Exception.Message) })
  }
  $names = @($obj.PSObject.Properties | ForEach-Object { $_.Name })
  $want = @('always_on_top', 'update_url', 'l2_budget_mib', 'l3_budget_mib', 'opacity')
  $missing = @($want | Where-Object { $names -notcontains $_ })
  $ok = ($missing.Count -eq 0) -and ([int]$obj.opacity -eq $Opacity)
  $detail = 'opacity={0} 字段={1}' -f $obj.opacity, ($names -join ',')
  if ($missing.Count -gt 0) { $detail += ' 缺=' + ($missing -join ',') }
  return (New-Object psobject -Property @{ Ok = $ok; Detail = $detail })
}

function Test-OttoMagic {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return (New-Object psobject -Property @{ Ok = $false; Detail = ('缺少 {0}' -f $Path) })
  }
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 8) {
    return (New-Object psobject -Property @{ Ok = $false; Detail = ('太短：{0} B' -f $bytes.Length) })
  }
  $magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 7)
  $ok = ($magic -eq 'OTTOLIB') -and ($bytes[7] -eq 0)
  return (New-Object psobject -Property @{ Ok = $ok; Detail = ('{0} B magic={1}<NUL>' -f $bytes.Length, $magic) })
}

# ---------------------------------------------------------------------------
# 目录树打印（卸载前后的"文件名 + 大小"表）
# ---------------------------------------------------------------------------

function Write-TreeTable {
  param([string]$Path, [string]$Title)
  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host ('  {0}：<不存在> {1}' -f $Title, $Path)
    return
  }
  $rows = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)
  Write-Host ('  {0}：{1}（{2} 个文件，{3:N0} B）' -f $Title, $Path, $rows.Count, (Get-TreeSize $Path))
  foreach ($row in $rows) {
    $rel = $row.FullName.Substring($Path.Length).TrimStart('\')
    Write-Host ('    {0,-28} {1,10:N0} B' -f $rel, $row.Length)
  }
}

# ---------------------------------------------------------------------------
# 第 0 步：前置条件（不满足就没法开始，直接 exit 1）
# ---------------------------------------------------------------------------

function Invoke-Preconditions {
  Start-Step 0 '前置条件'
  $have = Test-Path -LiteralPath $script:distDir -PathType Container
  Add-Check 'zig\dist 存在' $have $script:distDir
  if (-not $have) { Complete-Step; return $false }

  $versions = Get-DistVersions
  Add-Check 'dist 里有 setup.exe 产物' ($versions.Count -gt 0) ('{0} 个版本：{1}' -f $versions.Count, (($versions | Select-Object -First 3) -join ' / '))
  if ($versions.Count -eq 0) { Complete-Step; return $false }

  if ($Version) {
    $setup = Get-SetupPath $Version
    Add-Check ('指定版本 {0} 的 setup.exe 存在' -f $Version) (Test-Path -LiteralPath $setup -PathType Leaf) $setup
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { Complete-Step; return $false }
  }

  $haveKey = Test-Path -LiteralPath $script:publicKey -PathType Leaf
  Add-Check 'minisign 公钥存在' $haveKey $script:publicKey
  $haveJs = Test-Path -LiteralPath $script:verifyJs -PathType Leaf
  Add-Check 'verify-minisign.js 存在' $haveJs $script:verifyJs
  $node = Get-Command node -ErrorAction SilentlyContinue
  Add-Check 'node 可用（验签要用）' ($null -ne $node) ($(if ($null -ne $node) { $node.Source } else { '找不到 node' }))
  $haveSamples = Test-Path -LiteralPath $script:samplesDir -PathType Container
  Add-Check '样例素材目录存在（第 6 步要导入）' $haveSamples $script:samplesDir
  $haveZigOut = Test-Path -LiteralPath $script:zigOutBin -PathType Container
  if ($haveZigOut) {
    Add-Check 'zig-out\bin 存在（第 9 步要比对它）' $true $script:zigOutBin
  } else {
    Add-Skip 'zig-out\bin 存在（第 9 步要比对它）' '没有编译产物，步骤 9 只能 SKIP（先 zig build）'
  }
  Complete-Step

  $failed = $script:stepFailed[0]
  return ($failed -eq 0)
}

# ---------------------------------------------------------------------------
# 收尾
# ---------------------------------------------------------------------------

# 放在 finally 里：杀残留进程 → 恢复环境变量 → 删临时树 → 核对 %TEMP% 没有多出东西。
function Invoke-Cleanup {
  try {
    $left = @(Get-ProcessUnder -Root $script:tempRoot)
    if ($left.Count -gt 0) {
      $idle = Wait-NoProcessUnder -Root $script:tempRoot -TimeoutSeconds 5
      if (-not $idle.Clear) {
        foreach ($proc in @($idle.Left)) {
          try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
        }
        $script:cleanup.LeftoverProcesses = @($idle.Left)
        $idle = Wait-NoProcessUnder -Root $script:tempRoot -TimeoutSeconds 10
      }
    }

    foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP')) {
      $before = $script:envBefore[$name]
      if ([string]::IsNullOrEmpty($before)) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
      } else {
        [Environment]::SetEnvironmentVariable($name, $before, 'Process')
      }
    }
    $restored = $true
    foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP')) {
      if ([Environment]::GetEnvironmentVariable($name, 'Process') -ne $script:envBefore[$name]) { $restored = $false }
    }
    $script:cleanup.EnvRestored = $restored

    if ($script:tempRoot -and (Test-Path -LiteralPath $script:tempRoot)) {
      if ($KeepTemp) {
        $script:cleanup.TempRemoved = $false
      } else {
        $script:cleanup.FreedBytes = Get-TreeSize $script:tempRoot
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
          Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
          if (-not (Test-Path -LiteralPath $script:tempRoot)) { break }
          Start-Sleep -Milliseconds 300
        }
        $script:cleanup.TempRemoved = -not (Test-Path -LiteralPath $script:tempRoot)
        if (-not $script:cleanup.TempRemoved) {
          $script:cleanup.Error = ('临时目录删不掉：{0}' -f $script:tempRoot)
        }
      }
    } else {
      $script:cleanup.TempRemoved = $true
    }
  } catch {
    $script:cleanup.Error = $_.Exception.Message
  }
}

function Write-CleanupReport {
  Write-Head '── 收尾 ──'

  $leftCount = @($script:cleanup.LeftoverProcesses).Count
  if ($leftCount -eq 0) {
    Write-Host '  [PASS] 没有残留进程'
  } else {
    Write-Host ('  [FAIL] 残留进程 {0} 个（已强杀）' -f $leftCount) -ForegroundColor Red
    foreach ($proc in @($script:cleanup.LeftoverProcesses)) {
      Write-Host ('         pid={0} {1} {2}' -f $proc.Id, $proc.Name, $proc.Path)
    }
  }

  if ($script:cleanup.EnvRestored) {
    Write-Host '  [PASS] 环境变量已恢复（APPDATA / LOCALAPPDATA / TEMP / TMP 与启动时一致）'
  } else {
    Write-Host '  [FAIL] 环境变量没恢复（见上）' -ForegroundColor Red
  }

  if ($KeepTemp) {
    Write-Host ('  [KEEP] 临时目录保留：{0}' -f $script:tempRoot)
  } elseif ($script:cleanup.TempRemoved) {
    Write-Host ('  [PASS] 临时目录已删除，释放 {0:N1} MB' -f ($script:cleanup.FreedBytes / 1MB))
  } else {
    Write-Host ('  [FAIL] 临时目录没删掉：{0}' -f $script:tempRoot) -ForegroundColor Red
  }
  if ($script:cleanup.Error) { Write-Host ('         ' + $script:cleanup.Error) }

  # 硬约束的最后一道：真实的 %APPDATA%\OTTO 一个文件都不该变。
  $realAfter = @(Get-TreeLightSnapshot $script:realOtto)
  $realSame = (@(Compare-Object -ReferenceObject @($script:realOttoBefore) -DifferenceObject @($realAfter)).Count -eq 0)
  $script:cleanup.RealOttoUnchanged = $realSame
  if ($realSame) {
    Write-Host ('  [PASS] 真实 %APPDATA%\OTTO 未被触碰（{0} 个文件，名字与大小一致）' -f $realAfter.Count)
  } else {
    Write-Host '  [FAIL] 真实 %APPDATA%\OTTO 变了（名字或大小不一致）' -ForegroundColor Red
    $delta = @(Compare-Object -ReferenceObject @($script:realOttoBefore) -DifferenceObject @($realAfter))
    foreach ($row in $delta) {
      Write-Host ('         {0} {1}' -f $row.SideIndicator, $row.InputObject)
    }
  }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

$script:tempRoot = Join-Path $env:TEMP ('otto-fresh-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:downloads = Join-Path $script:tempRoot 'downloads'
$script:programDir = Join-Path $script:tempRoot 'program'
$script:fakeAppData = Join-Path $script:tempRoot 'appdata'
$script:fakeLocalAppData = Join-Path $script:tempRoot 'localappdata'
$script:fakeTemp = Join-Path $script:tempRoot 'temp'
$script:shotsDir = Join-Path $script:tempRoot 'shots'
$script:importSrc = Join-Path $script:tempRoot 'import-src'
$script:outOtto = Join-Path $script:tempRoot 'out.otto'
$script:ottoData = Join-Path $script:fakeAppData 'OTTO'

$script:tempBefore = @()
if ($script:realTemp) {
  $script:tempBefore = @(Get-ChildItem -LiteralPath $script:realTemp -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}
# 真实用户目录的基线：收尾时要求它一个文件都没变（硬约束）。
$script:realOttoBefore = @(Get-TreeLightSnapshot $script:realOtto)

Write-Host 'OTTO Lite 全新用户测试'
Write-Host ('仓库：{0}' -f $script:repoRoot)
Write-Host ('临时根：{0}' -f $script:tempRoot)
if ($script:elevated) {
  Write-Host '会话：已提权（NSIS 原样运行：注册表 + 全用户快捷方式一并断言）'
} else {
  Write-Host '会话：非提权（__COMPAT_LAYER=RunAsInvoker；NSIS 的 HKLM / 全用户快捷方式两条写入被 /S 静默跳过）'
}

$script:setupPath = ''
$script:oldSetupPath = ''
$script:version = ''
$script:oldVersion = ''
$script:zigOutBefore = @()
$script:dataBeforeUninstall = @()

try {
  if (-not (Invoke-Preconditions)) {
    throw '前置条件不满足，测试无法开始'
  }

  $versions = Get-DistVersions
  if ($Version) { $script:version = $Version } else { $script:version = $versions[0] }
  $script:setupPath = Get-SetupPath $script:version
  Write-Host ('被测版本：{0}' -f $script:version)

  # 第 9 步的基线：必须在任何安装 / 运行之前取。
  if (Test-Path -LiteralPath $script:zigOutBin) {
    $script:zigOutBefore = @(Get-TreeSnapshot $script:zigOutBin)
  }

  # -------------------------------------------------------------------------
  # 1. 造全新目录
  # -------------------------------------------------------------------------
  Start-Step 1 '造全新目录（下载 / 程序 / 用户数据 / 本地数据）'
  foreach ($dir in @($script:downloads, $script:programDir, $script:fakeAppData, $script:fakeLocalAppData, $script:fakeTemp)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $allExist = $true
  foreach ($dir in @($script:downloads, $script:programDir, $script:fakeAppData, $script:fakeLocalAppData)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $allExist = $false }
  }
  Add-Check '四个目录都建好（downloads / program / appdata / localappdata）' $allExist $script:tempRoot

  $underTemp = $script:tempRoot.StartsWith([IO.Path]::GetFullPath($script:realTemp), [StringComparison]::OrdinalIgnoreCase)
  Add-Check '整个临时根在 %TEMP% 下（不碰真实 APPDATA / Program Files）' $underTemp ('%TEMP% = {0}' -f $script:realTemp)

  $noSpace = ($script:programDir -notmatch '\s')
  Add-Check '安装路径不含空格（NSIS 的 /D= 不带引号）' $noSpace $script:programDir

  $awayFromReal = $true
  foreach ($real in @($script:realOtto, $script:programFiles, $script:programFilesX86)) {
    if (-not $real) { continue }
    if ($script:programDir.StartsWith([IO.Path]::GetFullPath($real), [StringComparison]::OrdinalIgnoreCase)) { $awayFromReal = $false }
    if ($script:fakeAppData.StartsWith([IO.Path]::GetFullPath($real), [StringComparison]::OrdinalIgnoreCase)) { $awayFromReal = $false }
  }
  Add-Check '安装目录与假 APPDATA 都不在真实 %APPDATA% / Program Files 里' $awayFromReal (
    '真实 %APPDATA%\OTTO = {0}' -f $script:realOtto)
  Add-Check '目录是空的（全新用户，没有可继承的状态）' (@(Get-ChildItem -LiteralPath $script:programDir -Force).Count -eq 0) (
    'program\ 里 {0} 个条目' -f @(Get-ChildItem -LiteralPath $script:programDir -Force).Count)
  Complete-Step

  # -------------------------------------------------------------------------
  # 2. "下载"并验签
  # -------------------------------------------------------------------------
  Start-Step 2 '“下载”：拷 setup.exe 到 downloads，用公钥验签'
  $setupSource = $script:setupPath
  Add-Check 'dist 里的 setup.exe 存在' (Test-Path -LiteralPath $setupSource -PathType Leaf) $setupSource
  $sigSource = $setupSource + '.sig'
  Add-Check '同目录有 .sig 签名' (Test-Path -LiteralPath $sigSource -PathType Leaf) $sigSource

  $localSetup = Join-Path $script:downloads 'otto-lite-setup.exe'
  Copy-Item -LiteralPath $setupSource -Destination $localSetup -Force
  Copy-Item -LiteralPath $sigSource -Destination ($localSetup + '.sig') -Force
  $srcHash = Get-FileSha $setupSource
  $dlHash = Get-FileSha $localSetup
  $dlSize = (Get-Item -LiteralPath $localSetup).Length
  Add-Check '“下载”的字节与 dist 一致（SHA-256）' ($srcHash -eq $dlHash -and $dlHash.Length -eq 64) (
    'sha256={0}… {1:N0} B' -f $dlHash.Substring(0, 12), $dlSize)

  $verify = Test-ArtifactSignature -SignaturePath ($localSetup + '.sig') -ArtifactPath $localSetup
  Add-Check 'minisign 验签通过（exit 0）' ($verify.Code -eq 0) ('exit={0}；{1}' -f $verify.Code, ($verify.Lines -join ' '))
  if ($verify.Code -ne 0) { Write-FailureTail $verify.Lines 6 }

  # 反向对照：证明验签真的在看字节，而不是恒返回 0。
  $tamper = Join-Path $script:downloads 'tampered.exe'
  Copy-Item -LiteralPath $localSetup -Destination $tamper -Force
  $stream = [IO.File]::Open($tamper, [IO.FileMode]::Append, [IO.FileAccess]::Write)
  try { $stream.WriteByte(0x00) } finally { $stream.Dispose() }
  $tamperResult = Test-ArtifactSignature -SignaturePath ($localSetup + '.sig') -ArtifactPath $tamper
  Add-Check '改一个字节的副本验签必须失败（反向对照）' ($tamperResult.Code -ne 0) (
    'exit={0}（期望非 0）' -f $tamperResult.Code)
  Remove-Item -LiteralPath $tamper -Force -ErrorAction SilentlyContinue
  Complete-Step

  # -------------------------------------------------------------------------
  # 3. 静默安装
  # -------------------------------------------------------------------------
  Start-Step 3 '静默安装到 program（/S + /D=）'
  $install = Install-Package -SetupPath $localSetup -Target $script:programDir -Label 'setup.exe'
  Add-Check '安装器退出码 0' ($install.Code -eq 0) ('exit={0}；{1} s' -f $install.Code, $install.Seconds)
  if ($install.Code -ne 0) { Write-FailureTail $install.Lines 8 }

  $expected = @('otto-lite.exe', 'otto-thumb-host.exe', 'Uninstall.exe', 'README.txt')
  foreach ($name in $expected) {
    $path = Join-Path $script:programDir $name
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $size = 0
    if ($exists) { $size = (Get-Item -LiteralPath $path).Length }
    Add-Check ('安装目录里有 {0}' -f $name) ($exists -and $size -gt 0) ('{0:N0} B' -f $size)
  }
  $dataNextToExe = Test-Path -LiteralPath (Join-Path $script:programDir 'data')
  Add-Check '安装目录里没有 data\（数据不写 Program Files）' (-not $dataNextToExe) 'program\data 不存在'
  Add-Check 'setup.exe 装完仍留在 downloads（安装器不自我消化）' (Test-Path -LiteralPath $localSetup -PathType Leaf) $localSetup
  $installProcs = @(Get-ProcessUnder -Root $script:tempRoot)
  Add-Check '安装后没有残留进程' ($installProcs.Count -eq 0) ('{0} 个' -f $installProcs.Count)
  if ($script:elevated) {
    $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OTTO Lite'
    $regOk = Test-Path -LiteralPath $key
    Add-Check '（提权会话）卸载项写进了 HKLM' $regOk $key
    if ($regOk) {
      $displayVersion = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).DisplayVersion
      Add-Check '（提权会话）DisplayVersion 与被测版本一致' ($displayVersion -eq $script:version) ('{0}' -f $displayVersion)
    }
  } else {
    Add-Skip '（提权会话）卸载项写进了 HKLM' '非提权：NSIS 的 HKLM 写入被兼容层静默跳过，Program Files 与注册表零写入'
  }
  Complete-Step

  # -------------------------------------------------------------------------
  # 4. 首次启动：--version
  # -------------------------------------------------------------------------
  Start-Step 4 '首次启动 --version（无窗口）'
  $installedExe = Join-Path $script:programDir 'otto-lite.exe'
  $versionRun = Invoke-Native -ExePath $installedExe -ExeArguments '--version' -WorkDir $script:programDir -EnvMap (Get-ChildEnv)
  $versionLine = $versionRun.Out.Trim()
  $expectedLine = 'otto-lite {0} (installed)' -f $script:version
  Add-Check '--version 退出码 0' ($versionRun.Code -eq 0) ('exit={0}；{1} s' -f $versionRun.Code, $versionRun.Seconds)
  Add-Check '形态是 installed 且版本一致' ($versionLine -eq $expectedLine) ('输出了 “{0}”' -f $versionLine)
  Add-Check '--version 不创建用户数据目录（第一次启动不该凭空造状态）' (-not (Test-Path -LiteralPath $script:ottoData)) (
    '%APPDATA%\OTTO 在 --version 之后仍不存在')
  Complete-Step

  # -------------------------------------------------------------------------
  # 5. 首次真实启动（隐藏窗口）：设置面板 → appdata\OTTO
  # -------------------------------------------------------------------------
  Start-Step 5 '首次真实启动（隐藏窗口）：设置写进 %APPDATA%\OTTO'
  $shot = Join-Path $script:shotsDir 'first-run.png'
  New-Item -ItemType Directory -Force -Path $script:shotsDir | Out-Null
  $panelArgs = '--nanoui-snapshot="{0}" --nanoui-script={1}' -f $shot, $script:panelScript
  $panelRun = Invoke-Native -ExePath $installedExe -ExeArguments $panelArgs -WorkDir $script:programDir -EnvMap (Get-ChildEnv)
  Add-Check '设置面板那一跑退出码 0' ($panelRun.Code -eq 0) ('exit={0}；{1} s' -f $panelRun.Code, $panelRun.Seconds)
  Add-Check '窗口是隐藏的（--nanoui-snapshot 收了截图）' (Test-Path -LiteralPath $shot -PathType Leaf) (
    'png {0:N0} B' -f (Get-Item -LiteralPath $shot -ErrorAction SilentlyContinue).Length)

  $ottoExists = Test-Path -LiteralPath $script:ottoData -PathType Container
  Add-Check '%APPDATA%\OTTO 被创建' $ottoExists $script:ottoData
  $settingsPath = Join-Path $script:ottoData 'settings.json'
  $settings = Test-SettingsFile -Path $settingsPath
  Add-Check 'settings.json 存在且可解析（五个字段 + opacity=153）' $settings.Ok $settings.Detail
  $cacheDir = Join-Path $script:ottoData 'cache\thumbs'
  Add-Check 'cache\thumbs 也建在 %APPDATA%\OTTO 下' (Test-Path -LiteralPath $cacheDir -PathType Container) $cacheDir
  $dataNextToExe = Test-Path -LiteralPath (Join-Path $script:programDir 'data')
  $settingsNextToExe = Test-Path -LiteralPath (Join-Path $script:programDir 'settings.json')
  Add-Check '程序目录里没有 data\ 也没有 settings.json' ((-not $dataNextToExe) -and (-not $settingsNextToExe)) $script:programDir
  Write-TreeTable -Path $script:ottoData -Title '首次启动后的用户数据'
  Complete-Step

  # -------------------------------------------------------------------------
  # 6. 导入素材
  # -------------------------------------------------------------------------
  Start-Step 6 '导入素材：--import 与 --import-into 都要出 library.otto'
  New-Item -ItemType Directory -Force -Path $script:importSrc | Out-Null
  $picked = @()
  foreach ($name in @('img00.png', 'img01.png')) {
    $candidate = Join-Path $script:samplesDir $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $picked += $candidate }
  }
  if ($picked.Count -eq 0) {
    # 样例目录不在约定的文件上时，退到"前两个普通文件"，不让这一步无谓地红。
    $picked = @(Get-ChildItem -LiteralPath $script:samplesDir -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Length -gt 0 } | Sort-Object Name | Select-Object -First 2 | ForEach-Object { $_.FullName })
  }
  foreach ($file in $picked) { Copy-Item -LiteralPath $file -Destination $script:importSrc -Force }
  $importCount = @(Get-ChildItem -LiteralPath $script:importSrc -File).Count
  Add-Check '准备了 1–2 个素材' ($importCount -ge 1 -and $importCount -le 2) ('{0} 个：{1}' -f $importCount, (($picked | ForEach-Object { Split-Path $_ -Leaf }) -join '、'))

  $importArgs = '--import "{0}" --save "{1}"' -f $script:importSrc, $script:outOtto
  $importRun = Invoke-Native -ExePath $installedExe -ExeArguments $importArgs -WorkDir $script:programDir -EnvMap (Get-ChildEnv)
  Add-Check '--import 退出码 0' ($importRun.Code -eq 0) ('exit={0}；{1} s' -f $importRun.Code, $importRun.Seconds)
  $summary = ($importRun.Lines | Where-Object { $_ -match '^scanned=' } | Select-Object -Last 1)
  if (-not $summary) { $summary = '' }
  $added = 0
  $wroteBytes = 0
  $m = [regex]::Match($summary, '^scanned=(\d+) added=(\d+).* bytes=(\d+)')
  if ($m.Success) { $added = [int]$m.Groups[2].Value; $wroteBytes = [int]$m.Groups[3].Value }
  Add-Check '--import 的摘要说导入了 2 个素材' ($summary -ne '' -and $added -eq $importCount) (
    ('摘要：{0}' -f $summary))
  $outMagic = Test-OttoMagic -Path $script:outOtto
  Add-Check '--import 的 --save 产出 OTTOLIB 文件' $outMagic.Ok $outMagic.Detail
  $outSize = 0
  if (Test-Path -LiteralPath $script:outOtto -PathType Leaf) { $outSize = (Get-Item -LiteralPath $script:outOtto).Length }
  Add-Check '落盘字节数与摘要一致' ($wroteBytes -gt 0 -and $outSize -eq $wroteBytes) ('{0:N0} B' -f $outSize)

  # 真正的"全新用户"路径：不带 --save，让程序按运行形态自己决定落点。
  $intoArgs = '--import-into "{0}"' -f $script:importSrc
  $intoRun = Invoke-Native -ExePath $installedExe -ExeArguments $intoArgs -WorkDir $script:programDir -EnvMap (Get-ChildEnv)
  Add-Check '--import-into 退出码 0' ($intoRun.Code -eq 0) ('exit={0}；{1} s' -f $intoRun.Code, $intoRun.Seconds)
  $intoSummary = ($intoRun.Lines | Where-Object { $_ -match '^scanned=' } | Select-Object -Last 1)
  if (-not $intoSummary) { $intoSummary = '' }
  $libraryOtto = Join-Path $script:ottoData 'library.otto'
  Add-Check 'library.otto 出现在 %APPDATA%\OTTO' (Test-Path -LiteralPath $libraryOtto -PathType Leaf) $libraryOtto
  Add-Check '--import-into 的摘要指向 %APPDATA%\OTTO\library.otto' (
    $intoSummary -match ('wrote=' + [regex]::Escape($libraryOtto))) $intoSummary
  $libMagic = Test-OttoMagic -Path $libraryOtto
  Add-Check 'library.otto 是真正的 OTTOLIB 文件' $libMagic.Ok $libMagic.Detail

  $infoRun = Invoke-Native -ExePath $installedExe -ExeArguments ('--library-info "{0}"' -f $libraryOtto) -EnvMap (Get-ChildEnv)
  $samplesCount = -1
  $mi = [regex]::Match($infoRun.Text, 'samples=(\d+)')
  if ($mi.Success) { $samplesCount = [int]$mi.Groups[1].Value }
  Add-Check '装有新导入库的 --library-info 说 samples=2' (($infoRun.Code -eq 0) -and ($samplesCount -eq $importCount)) (
    'exit={0}；samples={1}' -f $infoRun.Code, $samplesCount)
  $dataNextToExe = Test-Path -LiteralPath (Join-Path $script:programDir 'data')
  Add-Check '导入没有往程序目录写东西' (-not $dataNextToExe) 'program\data 不存在'
  Complete-Step

  # -------------------------------------------------------------------------
  # 7. 静默卸载
  # -------------------------------------------------------------------------
  Start-Step 7 '静默卸载：程序消失，用户数据逐个文件保留'
  $script:dataBeforeUninstall = @(Get-TreeSnapshot $script:ottoData)
  Write-TreeTable -Path $script:ottoData -Title '卸载前'
  $uninstall = Uninstall-Package -ProgramDir $script:programDir
  Add-Check '卸载器退出码 0' ($uninstall.Code -eq 0) ('exit={0}；父进程 {1} s' -f $uninstall.Code, $uninstall.ExitSeconds)
  Add-Check 'program 目录整个消失' $uninstall.Gone ('{0} s 后不存在' -f $uninstall.GoneSeconds)
  if (-not $uninstall.Gone) {
    $left = @(Get-ChildItem -LiteralPath $script:programDir -Force -ErrorAction SilentlyContinue)
    Write-Host ('         残留：{0}' -f (($left | ForEach-Object { $_.Name }) -join '、'))
  }
  $clean = $uninstall.Processes
  $processDetail = ''
  if ($clean.Clear) {
    $processDetail = '{0} s 内退出' -f $clean.Seconds
  } else {
    $processDetail = '还活着：' + (($clean.Left | ForEach-Object { $_.Name }) -join '、')
  }
  Add-Check '卸载后没有残留进程（NSIS 的自删除副本也算）' $clean.Clear $processDetail

  $ottoStill = Test-Path -LiteralPath $script:ottoData -PathType Container
  Add-Check '%APPDATA%\OTTO 仍然存在' $ottoStill $script:ottoData
  $dataAfterUninstall = @(Get-TreeSnapshot $script:ottoData)
  $diff = Compare-TreeSnapshot $script:dataBeforeUninstall $dataAfterUninstall
  Add-Check '用户数据逐个文件一致（名字 + 大小 + SHA-256）' $diff.Ok (
    '卸载前 {0} 个文件 / 卸载后 {1} 个文件' -f @($script:dataBeforeUninstall).Count, @($dataAfterUninstall).Count)
  if (-not $diff.Ok) {
    if (@($diff.Removed).Count -gt 0) { Write-Host ('         消失：{0}' -f ($diff.Removed -join '、')) }
    if (@($diff.Added).Count -gt 0) { Write-Host ('         多出：{0}' -f ($diff.Added -join '、')) }
    if (@($diff.Changed).Count -gt 0) { Write-Host ('         内容变了：{0}' -f ($diff.Changed -join '、')) }
  }
  $cacheStill = Test-Path -LiteralPath (Join-Path $script:ottoData 'cache\thumbs') -PathType Container
  Add-Check '缓存目录也留着' $cacheStill 'cache\thumbs'
  Write-TreeTable -Path $script:ottoData -Title '卸载后'
  Complete-Step

  # -------------------------------------------------------------------------
  # 8. 装另一个版本
  # -------------------------------------------------------------------------
  Start-Step 8 '装另一个版本：旧数据被沿用'
  $candidates = @($versions | Where-Object { [version]$_ -lt [version]$script:version })
  if ($OldVersion) { $script:oldVersion = $OldVersion } elseif ($candidates.Count -gt 0) { $script:oldVersion = $candidates[0] }
  if (-not $script:oldVersion) {
    Add-Skip '装另一个（更旧的）版本' 'zig\dist 里没有比被测版本更旧的 setup.exe'
    Complete-Step
  } else {
    $script:oldSetupPath = Get-SetupPath $script:oldVersion
    Add-Check ('更旧版本的 setup.exe 存在（{0}）' -f $script:oldVersion) (Test-Path -LiteralPath $script:oldSetupPath -PathType Leaf) $script:oldSetupPath
    $oldSig = $script:oldSetupPath + '.sig'
    if (Test-Path -LiteralPath $oldSig -PathType Leaf) {
      $oldVerify = Test-ArtifactSignature -SignaturePath $oldSig -ArtifactPath $script:oldSetupPath
      Add-Check ('旧版本 setup.exe 验签通过（{0}）' -f $script:oldVersion) ($oldVerify.Code -eq 0) ('exit={0}' -f $oldVerify.Code)
    } else {
      Add-Skip '旧版本 setup.exe 验签' '这个版本没有 .sig'
    }

    $reinstall = Install-Package -SetupPath $script:oldSetupPath -Target $script:programDir -Label ('setup.exe ' + $script:oldVersion)
    Add-Check '旧版本安装退出码 0' ($reinstall.Code -eq 0) ('exit={0}；{1} s' -f $reinstall.Code, $reinstall.Seconds)
    $oldExe = Join-Path $script:programDir 'otto-lite.exe'
    $oldVersionRun = Invoke-Native -ExePath $oldExe -ExeArguments '--version' -WorkDir $script:programDir -EnvMap (Get-ChildEnv)
    $oldLine = $oldVersionRun.Out.Trim()
    Add-Check ('旧版本的 --version 说 {0} (installed)' -f $script:oldVersion) (
      ($oldVersionRun.Code -eq 0) -and ($oldLine -eq ('otto-lite {0} (installed)' -f $script:oldVersion))) (
        '输出了 “{0}”' -f $oldLine)

    $dataAfterOld = @(Get-TreeSnapshot $script:ottoData)
    $oldDiff = Compare-TreeSnapshot $script:dataBeforeUninstall $dataAfterOld
    Add-Check '旧版本沿用同一份用户数据（名字 + 大小 + SHA-256 未变）' $oldDiff.Ok (
      '{0} 个文件' -f @($dataAfterOld).Count)
    if (-not $oldDiff.Ok) {
      if (@($oldDiff.Removed).Count -gt 0) { Write-Host ('         消失：{0}' -f ($oldDiff.Removed -join '、')) }
      if (@($oldDiff.Added).Count -gt 0) { Write-Host ('         多出：{0}' -f ($oldDiff.Added -join '、')) }
      if (@($oldDiff.Changed).Count -gt 0) { Write-Host ('         内容变了：{0}' -f ($oldDiff.Changed -join '、')) }
    }
    $dataNextToExe = Test-Path -LiteralPath (Join-Path $script:programDir 'data')
    Add-Check '旧版本也没有在程序目录里造 data\' (-not $dataNextToExe) $script:programDir

    # 0.x 不承诺向下兼容（CHARTER 十）：旧版本能不能解析新格式只报告，不判定。
    $oldInfo = Invoke-Native -ExePath $oldExe -ExeArguments ('--library-info "{0}"' -f $libraryOtto) -EnvMap (Get-ChildEnv)
    Write-Info ('旧版本读 library.otto：exit={0} {1}' -f $oldInfo.Code, ($oldInfo.Text -replace "`r?`n", ' / ').Trim())

    $cleanupRun = Uninstall-Package -ProgramDir $script:programDir
    Add-Check '旧版本也能卸干净' ($cleanupRun.Code -eq 0 -and $cleanupRun.Gone) (
      'exit={0}；{1} s 后目录消失' -f $cleanupRun.Code, $cleanupRun.GoneSeconds)
    $afterFinal = @(Get-TreeSnapshot $script:ottoData)
    $finalDiff = Compare-TreeSnapshot $script:dataBeforeUninstall $afterFinal
    Add-Check '两次卸载之后用户数据仍然逐字节一致' $finalDiff.Ok ('{0} 个文件' -f @($afterFinal).Count)
    Complete-Step
  }

  # -------------------------------------------------------------------------
  # 9. 编译产物零污染
  # -------------------------------------------------------------------------
  Start-Step 9 '编译产物零污染（zig-out\bin 全程不变）'
  if (-not (Test-Path -LiteralPath $script:zigOutBin)) {
    Add-Skip 'zig-out\bin 内容零变化' '没有编译产物可以比对'
    Complete-Step
  } else {
    $after = @(Get-TreeSnapshot $script:zigOutBin)
    $before = @($script:zigOutBefore)
    $purity = Compare-TreeSnapshot $before $after
    Add-Check 'zig-out\bin 内容零变化（名字 + 大小 + SHA-256）' $purity.Ok (
      '{0} 个文件 / {1:N0} B' -f $after.Count, (Get-TreeSize $script:zigOutBin))
    if (-not $purity.Ok) {
      if (@($purity.Added).Count -gt 0) { Write-Host ('         多出：{0}' -f ($purity.Added -join '、')) }
      if (@($purity.Removed).Count -gt 0) { Write-Host ('         消失：{0}' -f ($purity.Removed -join '、')) }
      if (@($purity.Changed).Count -gt 0) { Write-Host ('         内容变了：{0}' -f ($purity.Changed -join '、')) }
    }
    foreach ($row in $after) { Write-Host ('    {0,-24} {1,12:N0} B  {2}…' -f $row.Rel, $row.Length, $row.Sha.Substring(0, 12)) }
    $dataNextToExe = Test-Path -LiteralPath (Join-Path $script:zigOutBin 'data')
    $settingsNextToExe = Test-Path -LiteralPath (Join-Path $script:zigOutBin 'settings.json')
    Add-Check 'zig-out\bin 里没有 data\ / settings.json' ((-not $dataNextToExe) -and (-not $settingsNextToExe)) $script:zigOutBin
    Complete-Step
  }
} catch {
  Write-Host ''
  Write-Host ('  [FAIL] 未预期错误：{0}' -f $_.Exception.Message) -ForegroundColor Red
  if ($_.ScriptStackTrace) { Write-Host ('         ' + ($_.ScriptStackTrace -split "`r?`n")[0]) }
  if ($script:currentStep -gt 0) {
    $script:stepTotal[$script:currentStep] = $script:stepTotal[$script:currentStep] + 1
    $script:stepFailed[$script:currentStep] = $script:stepFailed[$script:currentStep] + 1
    $null = $script:checks.Add((New-Object psobject -Property @{
      Step = $script:currentStep
      Name = '未预期错误（脚本中止）'
      Ok = $false
      Skip = $false
    }))
  }
} finally {
  Invoke-Cleanup
}

# ---------------------------------------------------------------------------
# 收尾核对：真实 %TEMP% 有没有多出我们要负责的东西
# ---------------------------------------------------------------------------
if ($script:realTemp) {
  $afterTemp = @(Get-ChildItem -LiteralPath $script:realTemp -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  $newEntries = @($afterTemp | Where-Object { $script:tempBefore -notcontains $_ })
  $script:cleanup.TempNewEntries = $newEntries
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
$script:clock.Stop()
$allChecks = @($script:checks)
$failed = @($allChecks | Where-Object { -not $_.Ok })
$skipped = @($allChecks | Where-Object { $_.Skip })
$passed = @($allChecks | Where-Object { $_.Ok -and -not $_.Skip })

Write-Head '── 汇总 ──'
$tableRows = @()
$header = @('步骤', '内容', '结果', '断言')
$widths = @(0, 0, 0, 0)
for ($i = 0; $i -lt $header.Count; $i++) { $widths[$i] = Get-DisplayWidth $header[$i] }
foreach ($number in @(0..9)) {
  if (-not $script:stepTitles.ContainsKey($number)) { continue }
  $total = $script:stepTotal[$number]
  $bad = $script:stepFailed[$number]
  $skipCount = $script:stepSkipped[$number]
  $verdict = 'PASS'
  if ($bad -gt 0) { $verdict = 'FAIL' }
  elseif ($total -eq $skipCount) { $verdict = 'SKIP' }
  $name = $script:stepTitles[$number]
  if ($number -eq 0) { $name = '前置条件' }
  $note = '{0}/{1} 项' -f ($total - $skipCount), $total
  if ($bad -gt 0) { $note = '{0} 项失败 / {1} 项' -f $bad, $total }
  $label = if ($number -eq 0) { '0' } else { [string]$number }
  $cells = @($label, $name, $verdict, $note)
  for ($i = 0; $i -lt $cells.Count; $i++) {
    $width = Get-DisplayWidth $cells[$i]
    if ($width -gt $widths[$i]) { $widths[$i] = $width }
  }
  $tableRows += , $cells
}
Write-Host ('  ' + (Format-Cells $header $widths))
foreach ($cells in $tableRows) { Write-Host ('  ' + (Format-Cells $cells $widths)) }
Write-Host ('  {0}' -f ('─' * 60))
Write-Host ('  断言：{0} PASS / {1} FAIL / {2} SKIP' -f $passed.Count, $failed.Count, $skipped.Count)
Write-Host ('  总耗时：{0:N1} s' -f $script:clock.Elapsed.TotalSeconds)

$stepsDesigned = 9
$stepsRun = 0
$stepsPassed = 0
foreach ($number in @(1..9)) {
  if (-not $script:stepTitles.ContainsKey($number)) { continue }
  $stepsRun++
  if ($script:stepFailed[$number] -eq 0) { $stepsPassed++ }
}

Write-CleanupReport

$cleanupOk = ($script:cleanup.LeftoverProcesses.Count -eq 0) -and $script:cleanup.EnvRestored -and
  ($KeepTemp -or $script:cleanup.TempRemoved) -and ($script:cleanup.TempNewEntries.Count -eq 0) -and
  $script:cleanup.RealOttoUnchanged -and (-not $script:cleanup.Error)

if ($script:cleanup.TempNewEntries.Count -gt 0) {
  Write-Host ('  [FAIL] 真实 %TEMP% 里多出了东西：{0}' -f ($script:cleanup.TempNewEntries -join '、')) -ForegroundColor Red
}

$ok = ($failed.Count -eq 0) -and $cleanupOk
Write-Host ''
$oldLabel = ''
if ($script:oldVersion) { $oldLabel = $script:oldVersion } else { $oldLabel = 'none' }
if ($ok) {
  Write-Host ('全新用户测试通过：{0} 步 / {1} 项断言' -f $stepsPassed, $passed.Count) -ForegroundColor Green
  # 机器可读的一行（纯 ASCII）：health.ps1 的 -Fresh 只认这一行。
  Write-Host ('fresh-user: PASS steps={0}/{1} checks={2}/{3} skip={4} version={5} old={6} sec={7:N1}' -f
    $stepsPassed, $stepsDesigned, $passed.Count, $allChecks.Count, $skipped.Count, $script:version, $oldLabel, $script:clock.Elapsed.TotalSeconds)
  Write-Host ('被测版本 {0}{1}' -f $script:version, $(if ($script:oldVersion) { '；另一个版本 ' + $script:oldVersion } else { '' }))
  exit 0
} else {
  Write-Host ('全新用户测试失败：{0} 项断言红了' -f $failed.Count) -ForegroundColor Red
  Write-Host ('fresh-user: FAIL steps={0}/{1} checks={2}/{3} failed={4} version={5} old={6} sec={7:N1}' -f
    $stepsPassed, $stepsDesigned, $passed.Count, $allChecks.Count, $failed.Count, $script:version, $oldLabel, $script:clock.Elapsed.TotalSeconds)
  exit 1
}
