param(
  [ValidateSet('x86', 'x64', 'all')]
  [string]$Arch = 'all'
)

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
$architectures = if ($Arch -eq 'all') { @('x86', 'x64') } else { @($Arch) }

function Build-Tool([string]$Architecture, [string]$Name, [string]$MainSource) {
  $bin = Join-Path $root "bin\$Architecture"
  $obj = Join-Path $root "obj\$Architecture\$Name"
  New-Item -ItemType Directory -Force -Path $bin, $obj | Out-Null

  $common = Join-Path $root 'common\dnd_common.cpp'
  $main = Join-Path $root $MainSource
  $exe = Join-Path $bin "$Name.exe"
  $compile = 'cl.exe /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 ' +
    '/DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN ' +
    "`"$common`" `"$main`" /Fe:`"$exe`" " +
    '/link /SUBSYSTEM:WINDOWS ole32.lib shell32.lib shlwapi.lib uuid.lib user32.lib gdi32.lib'
  $command = "call `"$vcvars`" $Architecture >nul && $compile"

  Push-Location $obj
  try {
    & cmd.exe /d /s /c $command
    if ($LASTEXITCODE -ne 0) {
      throw "$Name $Architecture build failed with exit code $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }
}

foreach ($architecture in $architectures) {
  Build-Tool $architecture 'DropInspector' 'DropInspector\main.cpp'
  Build-Tool $architecture 'DragProbe' 'DragProbe\main.cpp'
}

Get-ChildItem (Join-Path $root 'bin') -Recurse -Filter *.exe |
  Select-Object FullName, Length, LastWriteTime
