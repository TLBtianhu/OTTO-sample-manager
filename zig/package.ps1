# 打一个便携版分发包。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File package.ps1 -Version 0.1.0
#
# 产物：dist\otto-lite-<version>-portable\ 与同名 .zip
# 里面只有分发物该有的东西：release exe、便携标记、说明、许可证。
# 开发产物 zig-out\bin\ 不参与分发，也不在 zip 里。
param(
  [string]$Version = '0.1.0',
  [string]$AppDir = 'C:\src\otto-zig-lite\zig\app',
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe',
  [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'dist' }

Write-Output "== 构建 release =="
Push-Location $AppDir
try {
  & $Zig build -Drelease=true
  if ($LASTEXITCODE -ne 0) { throw "构建失败 ($LASTEXITCODE)" }
} finally { Pop-Location }

$exe = Join-Path $AppDir 'zig-out\bin\otto-lite.exe'
if (-not (Test-Path $exe)) { throw "没有产物: $exe" }

$name = "otto-lite-$Version-portable"
$stage = Join-Path $OutDir $name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item $exe (Join-Path $stage 'otto-lite.exe')

# 便携版的判据：exe 同目录有标记文件 → 数据写在自己的 data\ 下。
[System.IO.File]::WriteAllText((Join-Path $stage 'otto-portable.flag'), '', [System.Text.UTF8Encoding]::new($false))

$readme = @"
OTTO Lite $Version（便携版）

双击 otto-lite.exe 使用。数据保存在本目录的 data\ 下，删掉整个文件夹就是干净卸载。

不要删除 otto-portable.flag：它是"我是便携版"的唯一判据，删了程序会按安装版处理，
把数据写到 %APPDATA%\OTTO。

命令行：
  otto-lite.exe [library.json] [--watch <dir>] [--select=0,1]
  otto-lite.exe --demo-transport
  otto-lite.exe --copy-now <file>
"@
[System.IO.File]::WriteAllText((Join-Path $stage 'README.txt'), $readme, [System.Text.UTF8Encoding]::new($false))

$license = Join-Path (Split-Path (Split-Path $AppDir -Parent) -Parent) 'LICENSE'
if (Test-Path $license) { Copy-Item $license (Join-Path $stage 'LICENSE') }

$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal

Write-Output ''
Write-Output "== 产物 =="
Get-ChildItem $stage | ForEach-Object { "{0,-22} {1,10:N0} B" -f $_.Name, $_.Length }
$zi = Get-Item $zip
"{0,-22} {1,10:N0} B" -f $zi.Name, $zi.Length
Write-Output ''
Write-Output ("文件夹: " + $stage)
Write-Output ("压缩包: " + $zip)
