$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
  throw 'Visual Studio Installer vswhere.exe was not found.'
}

$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) {
  throw 'Visual C++ build tools are not installed.'
}

$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
$source = Join-Path $root 'otto-drag-helper\main.cpp'
$output = Join-Path $root 'otto-drag-helper.exe'
$build = Join-Path $root '.build'
$object = Join-Path $build 'otto-drag-helper.obj'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$compile = 'cl.exe /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /O2 /MT ' +
  '/DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN ' +
  "`"$source`" /Fo:`"$object`" /Fe:`"$output`" " +
  '/link /SUBSYSTEM:WINDOWS /OPT:REF /OPT:ICF ole32.lib shell32.lib user32.lib'
$command = "call `"$vcvars`" x86 >nul && $compile"

& cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) {
  throw "otto-drag-helper x86 build failed with exit code $LASTEXITCODE."
}

Get-Item -LiteralPath $output | Select-Object FullName, Length, LastWriteTime
