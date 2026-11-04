# OTTO 单根目录生命周期验收。只运行 OTTO_TEST 构建：不写真实注册表/快捷方式，不弹窗。
# 正常：pwsh zig/fresh-user.ps1
# 反向：pwsh zig/fresh-user.ps1 -FaultDataLoss（必须 exit 1，且数据保留断言为红）
[CmdletBinding()]
param(
  [string]$DistDir = '',
  [string]$Version = '',
  [string]$OldVersion = '',
  [string]$FromSetup = '',
  [string]$ToSetup = '',
  [switch]$FaultDataLoss,
  [switch]$KeepTemp
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $DistDir) { $DistDir = Join-Path $PSScriptRoot 'dist' }
$script:dist = [IO.Path]::GetFullPath($DistDir)
$script:checks = [Collections.ArrayList]::new()
$script:step = 0
$script:stepCount = 6
$script:clock = [Diagnostics.Stopwatch]::StartNew()
$script:failedNames = @()
$script:root = ''
$script:reference = ''
$script:temp = ''

function Add-Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  [void]$script:checks.Add([pscustomobject]@{ Step = $script:step; Name = $Name; Ok = $Ok })
  if (-not $Ok) { $script:failedNames += $Name }
  Write-Host ('  [{0}] {1}{2}' -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name,
    $(if ($Detail) { '   ' + $Detail } else { '' }))
}
function Step([int]$N, [string]$Title) {
  $script:step = $N
  Write-Host ("`n── 步骤 {0}/{1}：{2} ──" -f $N, $script:stepCount, $Title)
}
function Get-Sha([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Get-Tree([string]$Path) {
  $rows = @()
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $rows }
  foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName)) {
    $rows += [pscustomobject]@{
      Rel = $file.FullName.Substring($Path.Length).TrimStart('\')
      Length = $file.Length
      Sha = Get-Sha $file.FullName
    }
  }
  return $rows
}
function Compare-Tree($Before, $After) {
  $a = @{}; $b = @{}
  foreach ($row in @($Before)) { if ($null -ne $row) { $a[$row.Rel] = $row } }
  foreach ($row in @($After)) { if ($null -ne $row) { $b[$row.Rel] = $row } }
  $added = @($b.Keys | Where-Object { -not $a.ContainsKey($_) })
  $removed = @($a.Keys | Where-Object { -not $b.ContainsKey($_) })
  $changed = @($a.Keys | Where-Object {
    $b.ContainsKey($_) -and ($a[$_].Sha -ne $b[$_].Sha -or $a[$_].Length -ne $b[$_].Length)
  })
  return [pscustomobject]@{
    Ok = $added.Count -eq 0 -and $removed.Count -eq 0 -and $changed.Count -eq 0
    Added = $added; Removed = $removed; Changed = $changed
  }
}
function Show-Diff($Diff) {
  if ($Diff.Added.Count) { Write-Host ('         多出：' + ($Diff.Added -join '、')) }
  if ($Diff.Removed.Count) { Write-Host ('         消失：' + ($Diff.Removed -join '、')) }
  if ($Diff.Changed.Count) { Write-Host ('         内容变化：' + ($Diff.Changed -join '、')) }
}
function Get-ChildEnv {
  return @{ APPDATA = $script:fakeAppData; LOCALAPPDATA = $script:fakeLocal;
    TEMP = $script:fakeTemp; TMP = $script:fakeTemp }
}
function Invoke-Native([string]$Exe, [string]$Arguments, [int]$TimeoutSeconds = 90) {
  Write-Host ('  $ "{0}" {1}' -f $Exe, $Arguments)
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $Exe; $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  foreach ($entry in (Get-ChildEnv).GetEnumerator()) {
    $psi.EnvironmentVariables[$entry.Key] = [string]$entry.Value
  }
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    $p.Kill(); throw "子进程超时：$Exe"
  }
  $result = [pscustomobject]@{ Code = $p.ExitCode; Out = [string]$out.Result;
    Err = [string]$err.Result; Text = ([string]$out.Result + [string]$err.Result) }
  $p.Dispose(); return $result
}
function Install-Test([string]$Setup, [string]$Target) {
  # /D 必须最后；即使根含空格也不加引号，NSIS 会把剩余部分整体当作根。
  $run = Invoke-Native $Setup ('/S /D=' + $Target) 120
  Add-Check '静默安装成功（/S + 自定义 /D= 根）' ($run.Code -eq 0) "exit=$($run.Code) root=$Target"
  return $run
}
function Wait-Gone([string]$Path) {
  for ($i = 0; $i -lt 200; $i++) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    Start-Sleep -Milliseconds 50
  }
  return (-not (Test-Path -LiteralPath $Path))
}
function Uninstall-Test([string]$Root, [string]$Choice = '') {
  $uninstaller = Join-Path $Root 'app\Uninstall.exe'
  $arguments = '/S'
  if ($Choice) { $arguments += ' /OTTO_TEST_CLEAN=' + $Choice }
  $run = Invoke-Native $uninstaller $arguments 120
  $gone = Wait-Gone (Join-Path $Root 'app')
  Add-Check $(if ($Choice) { "勾选 $Choice 的卸载执行成功" } else { '默认静默卸载执行成功' }) (
    $run.Code -eq 0 -and $gone) "exit=$($run.Code) appGone=$gone"
}
function New-DataAndCache([string]$Root, [bool]$RunApp) {
  $exe = Join-Path $Root 'app\otto-lite.exe'
  if ($RunApp) {
    $shot = Join-Path $script:temp 'shots\settings.png'
    New-Item -ItemType Directory -Force -Path (Split-Path $shot -Parent) | Out-Null
    $panel = '--nanoui-snapshot="{0}" --nanoui-script={1}' -f $shot, 'click:设置;at:298,222;click:关闭'
    $gui = Invoke-Native $exe $panel
    Add-Check '隐藏窗口写入真实 settings.json（不弹窗、不抢焦点）' (
      $gui.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $Root 'data\settings.json') -PathType Leaf)
    ) "exit=$($gui.Code)"
    $import = Invoke-Native $exe ('--import-into "{0}"' -f (Split-Path $script:sample -Parent))
    Add-Check '真实导入生成 <根>\data\library.otto' (
      $import.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $Root 'data\library.otto') -PathType Leaf)
    ) "exit=$($import.Code)"
  }
  foreach ($pair in @(
    @('data\acceptance-marker.bin', [byte[]](1,2,3,4,5)),
    @('cache\thumbs\acceptance-marker.bin', [byte[]](9,8,7,6,5,4))
  )) {
    $path = Join-Path $Root $pair[0]
    New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
    [IO.File]::WriteAllBytes($path, $pair[1])
  }
}
function Get-Versions {
  $map = @{}
  foreach ($f in @(Get-ChildItem -LiteralPath $script:dist -Filter 'otto-lite-*-test-setup.exe' -File -ErrorAction SilentlyContinue)) {
    $m = [regex]::Match($f.Name, '^otto-lite-(\d+\.\d+\.\d+)-test-setup\.exe$')
    if ($m.Success) { $map[$m.Groups[1].Value] = $f.FullName }
  }
  return $map
}
function New-Sample {
  # 极小、合法的 PCM WAV，避免依赖机器上的外部素材目录。
  $path = Join-Path $script:temp 'fixture.wav'
  $stream = [IO.File]::Create($path); $w = [IO.BinaryWriter]::new($stream)
  try {
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([uint32]68)
    $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $w.Write([uint32]16)
    $w.Write([uint16]1); $w.Write([uint16]1); $w.Write([uint32]8000)
    $w.Write([uint32]16000); $w.Write([uint16]2); $w.Write([uint16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([uint32]32)
    for ($i = 0; $i -lt 16; $i++) { $w.Write([int16]($i * 100)) }
  } finally { $w.Dispose(); $stream.Dispose() }
  return $path
}

try {
  Step 1 '隔离环境、产物与用户级安装契约'
  $versions = Get-Versions
  Add-Check '至少两个单根测试安装器（v1 与新版）' ($versions.Count -ge 2 -or ($FromSetup -and $ToSetup)) (
    '用 package.ps1 -TestSetupOut 生成 otto-lite-<版本>-test-setup.exe')
  if ($versions.Count -lt 2 -and (-not $FromSetup -or -not $ToSetup)) { throw '缺少升级起止安装器' }
  if (-not $ToSetup) {
    if (-not $Version) { $Version = @($versions.Keys | Sort-Object { [version]$_ } -Descending)[0] }
    $ToSetup = $versions[$Version]
  }
  if (-not $FromSetup) {
    if (-not $OldVersion) {
      $OldVersion = @($versions.Keys | Where-Object { $_ -ne $Version } |
        Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
    }
    $FromSetup = $versions[$OldVersion]
  }
  Add-Check 'v1 / 新版安装器都存在' ((Test-Path -LiteralPath $FromSetup -PathType Leaf) -and
    (Test-Path -LiteralPath $ToSetup -PathType Leaf)) "$FromSetup -> $ToSetup"
  if (-not (Test-Path -LiteralPath $FromSetup) -or -not (Test-Path -LiteralPath $ToSetup)) { throw '安装器路径无效' }
  if (-not $Version) { $Version = [regex]::Match((Split-Path $ToSetup -Leaf), '\d+\.\d+\.\d+').Value }
  if (-not $OldVersion) { $OldVersion = [regex]::Match((Split-Path $FromSetup -Leaf), '\d+\.\d+\.\d+').Value }

  $nsi = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installer.nsi') -Raw
  $un = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installer-uninstall.nsh') -Raw
  Add-Check '默认根是用户级 Programs\OTTO，且无需管理员' (
    $nsi.Contains('InstallDir "$LOCALAPPDATA\Programs\OTTO"') -and
    $nsi.Contains('RequestExecutionLevel user') -and -not $nsi.Contains('RequestExecutionLevel admin'))
  Add-Check '图形目录页与 HKCU 卸载注册均启用' (
    $nsi.Contains('!insertmacro MUI_PAGE_DIRECTORY') -and $nsi.Contains('WriteRegStr HKCU'))
  Add-Check '卸载页默认主程序勾选、data/cache 不勾选' (
    $un.Contains('${NSD_Check} $OttoMainCheck') -and
    $un.Contains('${NSD_Uncheck} $OttoDataCheck') -and
    $un.Contains('${NSD_Uncheck} $OttoCacheCheck'))
  Add-Check '全选有独立再次确认；静默页有安全默认' (
    $un.Contains('OTTO_UN_ALL_CONFIRM') -and $un.Contains('MessageBox MB_YESNO') -and
    $un.Contains('${If} ${Silent}'))

  $script:temp = Join-Path $env:TEMP ('otto-install-root-' + [guid]::NewGuid().ToString('N'))
  $script:root = Join-Path $script:temp 'custom root' # 同时验证 /D= 支持空格。
  $script:reference = Join-Path $script:temp 'reference'
  $script:fakeAppData = Join-Path $script:temp 'fake-roaming'
  $script:fakeLocal = Join-Path $script:temp 'fake-local'
  $script:fakeTemp = Join-Path $script:temp 'fake-temp'
  foreach ($dir in @($script:temp, $script:fakeAppData, $script:fakeLocal, $script:fakeTemp)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $script:sample = New-Sample
  $legacy = Join-Path $script:fakeAppData 'OTTO'
  New-Item -ItemType Directory -Force -Path $legacy | Out-Null
  [IO.File]::WriteAllText((Join-Path $legacy 'settings.json'), '{"opacity":1,"legacy":true}')
  [IO.File]::WriteAllBytes((Join-Path $legacy 'library.otto'), [byte[]](0x4f,0x4c,0x44))
  $script:legacyBefore = @(Get-Tree $legacy)
  Add-Check '旧 APPDATA 库已放置为毒丸；新根尚不存在' (
    (Test-Path -LiteralPath $legacy) -and -not (Test-Path -LiteralPath $script:root))

  Step 2 '安装 v1，首次运行生成新库、设置与缓存'
  Install-Test $FromSetup $script:root | Out-Null
  foreach ($name in @('otto-lite.exe', 'otto-thumb-host.exe', 'Uninstall.exe')) {
    Add-Check "app 中有 $name" (Test-Path -LiteralPath (Join-Path $script:root "app\$name") -PathType Leaf)
  }
  Add-Check '安装器不创建 data 或 cache' (
    -not (Test-Path -LiteralPath (Join-Path $script:root 'data')) -and
    -not (Test-Path -LiteralPath (Join-Path $script:root 'cache')))
  New-DataAndCache $script:root $true
  $script:data = Join-Path $script:root 'data'; $script:cache = Join-Path $script:root 'cache'
  $script:dataBefore = @(Get-Tree $script:data); $script:cacheBefore = @(Get-Tree $script:cache)
  Add-Check 'v1 数据基线包含真实库、设置和标记' (
    (Test-Path -LiteralPath (Join-Path $script:data 'library.otto')) -and
    (Test-Path -LiteralPath (Join-Path $script:data 'settings.json')) -and $script:dataBefore.Count -ge 3)
  Add-Check '缓存在根的兄弟目录，不在 data\cache' (
    $script:cacheBefore.Count -ge 1 -and -not (Test-Path -LiteralPath (Join-Path $script:data 'cache')))
  Add-Check '旧结构没有迁移到新库（首次运行只使用新根）' (
    -not (Test-Path -LiteralPath (Join-Path $script:data 'library.json')))

  Step 3 '覆盖升级：app 全量替换，data/cache 逐字节不变'
  Install-Test $ToSetup $script:reference | Out-Null
  $referenceApp = @(Get-Tree (Join-Path $script:reference 'app'))
  [IO.File]::WriteAllText((Join-Path $script:root 'app\obsolete-v1.txt'), 'must disappear')
  if ($FaultDataLoss) {
    Move-Item -LiteralPath (Join-Path $script:data 'settings.json') -Destination (Join-Path $script:data 'settings.json.lost') -Force
    Write-Host '  [FAULT] 已模拟升级丢失 settings.json；下面的保留断言必须红。'
  }
  Install-Test $ToSetup $script:root | Out-Null
  $appDiff = Compare-Tree $referenceApp @(Get-Tree (Join-Path $script:root 'app'))
  Add-Check '覆盖后的 app 与新版全新安装逐文件、逐字节一致' $appDiff.Ok (
    "files=$($referenceApp.Count) changed=$($appDiff.Changed.Count) added=$($appDiff.Added.Count) removed=$($appDiff.Removed.Count)")
  if (-not $appDiff.Ok) { Show-Diff $appDiff }
  Add-Check 'v1 遗留文件被 app 全量替换清除' (-not (Test-Path -LiteralPath (Join-Path $script:root 'app\obsolete-v1.txt')))
  $dataAfter = @(Get-Tree $script:data); $cacheAfter = @(Get-Tree $script:cache)
  # 无故障时 beforeUpgrade == dataBefore；故障时用它证明比较器确实能红。
  $dataDiff = Compare-Tree $script:dataBefore $dataAfter
  $cacheDiff = Compare-Tree $script:cacheBefore $cacheAfter
  Add-Check '覆盖升级后整个 data 逐字节不变' $dataDiff.Ok (
    "before=$($script:dataBefore.Count) after=$($dataAfter.Count) added=$($dataDiff.Added.Count) removed=$($dataDiff.Removed.Count) changed=$($dataDiff.Changed.Count)")
  Add-Check '覆盖升级后整个 cache 逐字节不变' $cacheDiff.Ok (
    "before=$($script:cacheBefore.Count) after=$($cacheAfter.Count) added=$($cacheDiff.Added.Count) removed=$($cacheDiff.Removed.Count) changed=$($cacheDiff.Changed.Count)")
  if (-not $dataDiff.Ok) { Show-Diff $dataDiff }; if (-not $cacheDiff.Ok) { Show-Diff $cacheDiff }
  $versionRun = Invoke-Native (Join-Path $script:root 'app\otto-lite.exe') '--version'
  Add-Check '新版 exe 已就位且仍识别为 installed' (
    $versionRun.Code -eq 0 -and $versionRun.Out.Trim() -eq "otto-lite $Version (installed)") $versionRun.Out.Trim()
  $legacyDiff = Compare-Tree $script:legacyBefore @(Get-Tree $legacy)
  Add-Check '旧 %APPDATA%\OTTO 毒丸逐字节不变' $legacyDiff.Ok

  Step 4 '默认 /S 卸载：只删 app，data/cache 保留'
  Uninstall-Test $script:reference
  Uninstall-Test $script:root
  $defaultDataDiff = Compare-Tree $script:dataBefore @(Get-Tree $script:data)
  $defaultCacheDiff = Compare-Tree $script:cacheBefore @(Get-Tree $script:cache)
  Add-Check '默认卸载后 app 不存在，data 仍逐字节保留' (
    -not (Test-Path -LiteralPath (Join-Path $script:root 'app')) -and $defaultDataDiff.Ok)
  Add-Check '默认卸载后 cache 仍逐字节保留' $defaultCacheDiff.Ok
  if (-not $defaultDataDiff.Ok) { Show-Diff $defaultDataDiff }

  Step 5 '只有明确选择才删除 data/cache'
  Install-Test $ToSetup $script:root | Out-Null
  $cacheBeforeDataChoice = @(Get-Tree $script:cache)
  Uninstall-Test $script:root 'data'
  $cacheAfterDataChoice = Compare-Tree $cacheBeforeDataChoice @(Get-Tree $script:cache)
  Add-Check '勾选 data：data 删除、cache 保留' (
    -not (Test-Path -LiteralPath $script:data) -and $cacheAfterDataChoice.Ok)

  Install-Test $ToSetup $script:root | Out-Null
  New-Item -ItemType Directory -Force -Path $script:data | Out-Null
  [IO.File]::WriteAllText((Join-Path $script:data 'keep.json'), '{"kept":true}')
  $beforeCacheChoice = @(Get-Tree $script:data)
  Uninstall-Test $script:root 'cache'
  $dataAfterCacheChoice = Compare-Tree $beforeCacheChoice @(Get-Tree $script:data)
  Add-Check '勾选 cache：cache 删除、data 保留' (
    -not (Test-Path -LiteralPath $script:cache) -and $dataAfterCacheChoice.Ok)

  Install-Test $ToSetup $script:root | Out-Null
  New-DataAndCache $script:root $false
  Uninstall-Test $script:root 'all'
  Add-Check '全选：app/data/cache 全部删除' (
    -not (Test-Path -LiteralPath (Join-Path $script:root 'app')) -and
    -not (Test-Path -LiteralPath $script:data) -and -not (Test-Path -LiteralPath $script:cache))
  $left = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($script:temp, [StringComparison]::OrdinalIgnoreCase) })
  Add-Check '验收结束无残留进程' ($left.Count -eq 0) "count=$($left.Count)"

  Step 6 '汇总'
} catch {
  Add-Check '验收脚本未预期异常' $false $_.Exception.Message
} finally {
  if ($script:temp -and (Test-Path -LiteralPath $script:temp) -and -not $KeepTemp) {
    Remove-Item -LiteralPath $script:temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
$all = @($script:checks); $failed = @($all | Where-Object { -not $_.Ok })
$script:clock.Stop()
Write-Host ("`n断言：{0} PASS / {1} FAIL；data基线={2} 文件；cache基线={3} 文件；耗时={4:N1}s" -f
  ($all.Count - $failed.Count), $failed.Count, @($script:dataBefore).Count,
  @($script:cacheBefore).Count, $script:clock.Elapsed.TotalSeconds)
if ($FaultDataLoss) {
  Write-Host '反向证明：-FaultDataLoss 故意删除设置；本次必须 FAIL，若全绿才说明验收失效。'
}
$ok = $failed.Count -eq 0 -and -not $FaultDataLoss
$summary = 'fresh-user: {0} steps={1}/{2} checks={3}/{4} skip=0 version={5} old={6} failed={7} sec={8:N1}' -f
  $(if ($ok) { 'PASS' } else { 'FAIL' }), $(if ($ok) { 6 } else { 0 }), 6,
  ($all.Count - $failed.Count), $all.Count, $Version, $OldVersion, $failed.Count, $script:clock.Elapsed.TotalSeconds
Write-Host $summary
if ($failed.Count) { Write-Host ('红在：' + (($script:failedNames | Select-Object -First 6) -join ' / ')) }
exit $(if ($ok) { 0 } else { 1 })
