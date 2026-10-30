# 一条命令产出两个分发物（都在 dist\ 下）：
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\package.ps1 -Version 0.0.1
#
#   dist\otto-lite-<version>-portable.zip   exe + otto-portable.flag + README.txt + LICENSE
#   dist\otto-lite-<version>-setup.exe      NSIS 安装包（本机需要装 NSIS 3）
#
# 版本号只有一个来源：zig/app/build.zig.zon 的 .version。脚本先核对 -Version 与它一致，
# 再构建、再用 `otto-lite.exe --version` 复核 exe 里编进去的版本——三处对不上就直接失败，
# 不产出名字和内容不一致的包。
#
# 注意：安装包只构建、不运行。本脚本不写注册表、不建快捷方式、不装任何东西。

param(
  [string]$Version = '',
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe',
  [string]$Nsis = 'C:\Program Files (x86)\NSIS\makensis.exe',
  [string]$AppDir = '',
  [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not $Version) { throw '必须传 -Version <x.y.z>（例如 -Version 0.0.1）' }
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "版本号必须是 x.y.z（NSIS 的 VIProductVersion 只接受数字段）：$Version"
}

if (-not $AppDir) { $AppDir = Join-Path $PSScriptRoot 'app' }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'dist' }
$RepoRoot = Split-Path $PSScriptRoot -Parent

if (-not (Test-Path $Zig)) { throw "找不到 zig: $Zig" }
if (-not (Test-Path $Nsis)) { throw "找不到 makensis: $Nsis（NSIS 3 未安装？）" }
if (-not (Test-Path $AppDir)) { throw "找不到 app 目录: $AppDir" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---------------------------------------------------------------------------
# 1) 版本一致性：build.zig.zon 是唯一来源
# ---------------------------------------------------------------------------

$zonPath = Join-Path $AppDir 'build.zig.zon'
if (-not (Test-Path $zonPath)) { throw "找不到 $zonPath" }
$zonText = Get-Content $zonPath -Raw
if ($zonText -notmatch '\.version\s*=\s*"([^"]+)"') {
  throw "build.zig.zon 里没有 .version 字段（形如 .version = `"x.y.z`"）：$zonPath"
}
$manifestVersion = $Matches[1]
if ($manifestVersion -ne $Version) {
  throw "版本不一致：-Version $Version，但 build.zig.zon 是 $manifestVersion。先改清单，否则 exe 里编进去的版本和产物名会对不上。"
}

# ---------------------------------------------------------------------------
# 2) 构建 release
# ---------------------------------------------------------------------------

Write-Output '== 构建 release =='
Push-Location $AppDir
try {
  # Zig 0.17 的 standardOptimizeOption 只暴露 -Drelease；build.zig 里声明的
  # preferred_optimize_mode = .ReleaseSafe 就是 release 的落点。
  & $Zig build -Drelease=true
  if ($LASTEXITCODE -ne 0) { throw "构建失败（zig build 退出码 $LASTEXITCODE）" }
} finally { Pop-Location }

$exe = Join-Path $AppDir 'zig-out\bin\otto-lite.exe'
if (-not (Test-Path $exe)) { throw "没有产物: $exe" }

# 复核 exe 里的版本：build_options 注入错了会在这里暴露，而不是等用户装完才发现。
$reported = (& $exe --version | Out-String).Trim()
$expected = "otto-lite $Version (dev)"
if ($reported -ne $expected) {
  throw "exe 版本自检失败：期望 `"$expected`"，实际 `"$reported`""
}
Write-Output "exe 自检: $reported"

$license = Join-Path $RepoRoot 'LICENSE'
$icon = Join-Path $RepoRoot 'resources\icon.ico'

# ---------------------------------------------------------------------------
# 3) 便携版：exe + 标记 + README + LICENSE → zip
# ---------------------------------------------------------------------------

$name = "otto-lite-$Version-portable"
$portableStage = Join-Path $OutDir $name
if (Test-Path $portableStage) { Remove-Item $portableStage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $portableStage | Out-Null

Copy-Item $exe (Join-Path $portableStage 'otto-lite.exe')

# 便携版的唯一判据：exe 同目录有标记文件 → 数据写在自己的 data\ 下。
# 空文件即可；内容不是协议的一部分。
[System.IO.File]::WriteAllText(
  (Join-Path $portableStage 'otto-portable.flag'),
  '',
  [System.Text.UTF8Encoding]::new($false)
)

$portableReadme = @"
OTTO Lite $Version（便携版）

双击 otto-lite.exe 使用。数据保存在本目录的 data\ 下；把整个文件夹删掉就是干净卸载。

不要删除 otto-portable.flag：它是"我是便携版"的唯一判据。删了程序会按安装版处理，
把数据写到 %APPDATA%\OTTO。

命令行：
  otto-lite.exe [library.json] [--watch <dir>] [--select=0,1]
  otto-lite.exe --version
  otto-lite.exe --demo <dir> | --demo-thumbs <dir> | --demo-transport
  otto-lite.exe --copy-now <file>

版本：$Version
许可证：见同目录 LICENSE（MIT）。
"@
[System.IO.File]::WriteAllText(
  (Join-Path $portableStage 'README.txt'),
  $portableReadme,
  [System.Text.UTF8Encoding]::new($false)
)

if (Test-Path $license) { Copy-Item $license (Join-Path $portableStage 'LICENSE') }
else { Write-Warning "没有 LICENSE，便携包将缺少许可证文件: $license" }

$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $portableStage '*') -DestinationPath $zip -CompressionLevel Optimal
if (-not (Test-Path $zip)) { throw "压缩包没有生成: $zip" }
Remove-Item $portableStage -Recurse -Force

# ---------------------------------------------------------------------------
# 4) 安装包：NSIS 只吃一个 staging 目录（exe + README），不碰便携标记
# ---------------------------------------------------------------------------

$installerStage = Join-Path $OutDir "otto-lite-$Version-installer-stage"
if (Test-Path $installerStage) { Remove-Item $installerStage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $installerStage | Out-Null

Copy-Item $exe (Join-Path $installerStage 'otto-lite.exe')

$installedReadme = @"
OTTO Lite $Version（安装版）

程序安装在 Program Files\OTTO Lite，安装目录只放程序文件，不写任何用户数据。
用户数据（库、分组、标签）保存在 %APPDATA%\OTTO\，每个用户各自一份。
卸载会删除程序与快捷方式，但保留 %APPDATA%\OTTO；要彻底清理请手动删除该目录。

命令行（在安装目录下）：
  otto-lite.exe [library.json] [--watch <dir>] [--select=0,1]
  otto-lite.exe --version
  otto-lite.exe --demo <dir> | --demo-thumbs <dir> | --demo-transport
  otto-lite.exe --copy-now <file>

版本：$Version
许可证：见同目录 LICENSE（MIT）。
"@
[System.IO.File]::WriteAllText(
  (Join-Path $installerStage 'README.txt'),
  $installedReadme,
  [System.Text.UTF8Encoding]::new($false)
)

$setup = Join-Path $OutDir "otto-lite-$Version-setup.exe"
if (Test-Path $setup) { Remove-Item $setup -Force }

$nsisArgs = @(
  '/V2',
  # installer.nsi 是 UTF-8（无 BOM）；不声明输入字符集时 NSIS 会按 ANSI 读，
  # 中文字符串直接报 "Bad text encoding"。
  '/INPUTCHARSET',
  'UTF8',
  "/DVERSION=$Version",
  "/DSOURCE_DIR=$installerStage",
  "/DOUT_FILE=$setup"
)
if (Test-Path $icon) { $nsisArgs += "/DICON_FILE=$icon" } else { Write-Warning "没有图标，安装包用 NSIS 默认图标: $icon" }
if (Test-Path $license) { $nsisArgs += "/DLICENSE_FILE=$license" }
$nsisArgs += (Join-Path $PSScriptRoot 'installer.nsi')

Write-Output '== 构建 NSIS 安装包 =='
& $Nsis @nsisArgs
if ($LASTEXITCODE -ne 0) { throw "makensis 失败（退出码 $LASTEXITCODE）" }
if (-not (Test-Path $setup)) { throw "安装包没有生成: $setup" }
Remove-Item $installerStage -Recurse -Force

# ---------------------------------------------------------------------------
# 5) 账目：只有两个分发物，尺寸打出来
# ---------------------------------------------------------------------------

Write-Output ''
Write-Output '== 产物 =='
foreach ($artifact in @($zip, $setup)) {
  $item = Get-Item $artifact
  '{0,-40} {1,12:N0} B' -f $item.Name, $item.Length
}
Write-Output ''
Write-Output ("输出目录: " + $OutDir)
Write-Output '安装包只构建、未运行：本脚本不写注册表、不建快捷方式。'
